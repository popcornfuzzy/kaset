import Foundation
import Network

// MARK: - LocalAudioStreamServer

/// Serves the encoded audio stream over HTTP on the local network.
///
/// The Cast Default Media Receiver plays a URL the sender hands it, so Kaset becomes the media
/// server: it accepts the receiver's HTTP request and streams encoded audio to it as endless
/// chunked responses. Only one Cast device is targeted at a time, but the receiver may open more
/// than one connection (for example a probe connection followed by the playback connection), so all
/// streaming clients receive the same chunks.
@MainActor
final class LocalAudioStreamServer {
    /// Stream server configuration.
    struct Configuration: Sendable {
        /// MIME type advertised for the stream.
        var contentType: String = "audio/aac"

        /// Path the receiver must request.
        var path: String = "/kaset-cast.aac"

        /// Bytes of audio retained while no client is streaming. Keeping only the newest data means
        /// a receiver that connects late starts near the live edge instead of replaying history.
        var maximumPendingByteCount: Int = 64 * 1024

        /// Upper bound on simultaneous streaming clients.
        var maximumClientCount: Int = 4
    }

    /// A connected HTTP client.
    ///
    /// The client is only ever mutated on the main actor; the annotation exists because Network
    /// framework completions are `@Sendable` and hop back to the main actor with the client value.
    private final class Client: @unchecked Sendable {
        let connection: NWConnection
        var requestHead = Data()
        var hasParsedHead = false
        var isStreaming = false

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "com.sertacozercan.Kaset.cast.stream")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var pendingAudio = Data()

    /// Port the server listens on, available once ``start()`` succeeds.
    private(set) var port: UInt16?

    /// Called when the number of clients receiving the stream changes.
    var onStreamingClientCountChanged: ((Int) -> Void)?

    /// Called when the server reports an error it cannot recover from.
    var onError: ((String) -> Void)?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Number of clients currently receiving audio.
    var streamingClientCount: Int {
        self.clients.values.filter(\.isStreaming).count
    }

    /// The path component the receiver must request.
    var streamPath: String {
        self.configuration.path
    }

    /// Starts listening and resolves with the bound port.
    @discardableResult
    func start() async throws -> UInt16 {
        if let port = self.port {
            return port
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.accept(connection)
            }
        }

        self.listener = listener

        let port = try await withCheckedThrowingContinuation { continuation in
            let hasResolved = LockedFlag()

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self else { return }

                    switch state {
                    case .ready:
                        if !hasResolved.setIfUnset() {
                            if let boundPort = self.listener?.port?.rawValue {
                                continuation.resume(returning: boundPort)
                            } else {
                                continuation.resume(throwing: CastStreamServerError.missingPort)
                            }
                        }

                    case .failed(let error):
                        DiagnosticsLogger.cast.error("Stream server failed: \(error.localizedDescription)")
                        if !hasResolved.setIfUnset() {
                            continuation.resume(throwing: error)
                        }
                        self.onError?(error.localizedDescription)
                        self.stop()

                    case .cancelled:
                        if !hasResolved.setIfUnset() {
                            continuation.resume(throwing: CastStreamServerError.cancelled)
                        }

                    default:
                        break
                    }
                }
            }
            listener.start(queue: self.queue)
        }

        self.port = port
        DiagnosticsLogger.cast.info("Stream server listening on port \(port)")
        return port
    }

    /// Stops listening and drops every client.
    func stop() {
        self.listener?.stateUpdateHandler = nil
        self.listener?.newConnectionHandler = nil
        self.listener?.cancel()
        self.listener = nil
        self.port = nil

        for client in self.clients.values {
            client.connection.stateUpdateHandler = nil
            client.connection.cancel()
        }
        let hadClients = !self.clients.isEmpty
        self.clients.removeAll()
        self.pendingAudio.removeAll(keepingCapacity: false)

        if hadClients {
            self.onStreamingClientCountChanged?(0)
        }
    }

    /// Sends encoded audio to every streaming client.
    func enqueue(_ data: Data) {
        guard !data.isEmpty, self.port != nil else { return }

        let streamingClients = self.clients.values.filter(\.isStreaming)
        guard !streamingClients.isEmpty else {
            self.appendPending(data)
            return
        }

        let chunk = CastChunkedTransfer.encode(data)
        for client in streamingClients {
            client.connection.send(content: chunk, completion: .contentProcessed { error in
                if let error {
                    DiagnosticsLogger.cast.debug("Stream send failed: \(error.localizedDescription)")
                }
            })
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let client = Client(connection: connection)
        self.clients[ObjectIdentifier(client)] = client

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.receive(on: client)
                case .failed, .cancelled:
                    self.remove(client)
                default:
                    break
                }
            }
        }

        connection.start(queue: self.queue)
    }

    private func receive(on client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let data, !data.isEmpty {
                    self.handleIncoming(data, from: client)
                }

                if error != nil || isComplete {
                    self.remove(client)
                    return
                }

                // The receiver sends nothing after its request, but the receive loop has to stay
                // armed so a disconnect is noticed promptly.
                self.receive(on: client)
            }
        }
    }

    private func handleIncoming(_ data: Data, from client: Client) {
        guard !client.hasParsedHead else { return }

        client.requestHead.append(data)

        guard CastHTTPRequest.containsCompleteHead(client.requestHead) else {
            if client.requestHead.count > CastHTTPRequest.maximumHeadSize {
                DiagnosticsLogger.cast.warning("Dropping oversized HTTP request head")
                self.send(CastHTTPResponse.badRequest(), to: client, closeAfterwards: true)
            }
            return
        }

        guard let request = CastHTTPRequest.parse(client.requestHead) else {
            self.send(CastHTTPResponse.badRequest(), to: client, closeAfterwards: true)
            return
        }

        client.hasParsedHead = true

        guard request.path == self.configuration.path else {
            DiagnosticsLogger.cast.debug("Rejecting stream request for \(request.path)")
            self.send(CastHTTPResponse.notFound(), to: client, closeAfterwards: true)
            return
        }

        if request.method == "HEAD" {
            self.send(CastHTTPResponse.head(contentType: self.configuration.contentType), to: client, closeAfterwards: true)
            return
        }

        guard self.streamingClientCount < self.configuration.maximumClientCount else {
            DiagnosticsLogger.cast.warning("Rejecting stream client above the connection limit")
            self.send(CastHTTPResponse.notFound(), to: client, closeAfterwards: true)
            return
        }

        DiagnosticsLogger.cast.info("Cast receiver connected to the audio stream")
        client.isStreaming = true
        self.send(CastHTTPResponse.stream(contentType: self.configuration.contentType), to: client, closeAfterwards: false)

        // Start the receiver near the live edge with whatever audio is already buffered.
        if !self.pendingAudio.isEmpty {
            let buffered = self.pendingAudio
            self.pendingAudio.removeAll(keepingCapacity: true)
            client.connection.send(
                content: CastChunkedTransfer.encode(buffered),
                completion: .contentProcessed { _ in }
            )
        }

        self.onStreamingClientCountChanged?(self.streamingClientCount)
    }

    private func remove(_ client: Client) {
        let wasStreaming = client.isStreaming
        client.connection.stateUpdateHandler = nil
        client.connection.cancel()
        self.clients.removeValue(forKey: ObjectIdentifier(client))

        if wasStreaming {
            DiagnosticsLogger.cast.info("Cast receiver disconnected from the audio stream")
            self.onStreamingClientCountChanged?(self.streamingClientCount)
        }
    }

    private func send(_ data: Data, to client: Client, closeAfterwards: Bool) {
        client.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                DiagnosticsLogger.cast.debug("Stream response failed: \(error.localizedDescription)")
            }
            Task { @MainActor [weak self] in
                guard closeAfterwards else { return }
                self?.remove(client)
            }
        })
    }

    private func appendPending(_ data: Data) {
        self.pendingAudio.append(data)

        let limit = self.configuration.maximumPendingByteCount
        guard self.pendingAudio.count > limit else { return }
        self.pendingAudio.removeFirst(self.pendingAudio.count - limit)
    }
}

// MARK: - LockedFlag

/// A one-way flag used to resolve a continuation exactly once from a network callback.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    /// Returns `true` when the flag was already set, and sets it otherwise.
    func setIfUnset() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }

        if self.isSet {
            return true
        }
        self.isSet = true
        return false
    }
}

// MARK: - CastStreamServerError

/// Errors raised by the local audio stream server.
enum CastStreamServerError: LocalizedError {
    /// The listener became ready without reporting a port.
    case missingPort

    /// The listener stopped before it was ready.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingPort: "The audio stream server did not report a port."
        case .cancelled: "The audio stream server stopped before it was ready."
        }
    }
}
