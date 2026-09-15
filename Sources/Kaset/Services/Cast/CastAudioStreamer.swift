import Foundation

// MARK: - CastAudioStreamerError

/// Errors raised while preparing the audio stream.
enum CastAudioStreamerError: LocalizedError {
    /// No local interface could be found for the device to dial back to.
    case noLocalAddress

    var errorDescription: String? {
        switch self {
        case .noLocalAddress:
            "No local network address is available to send audio from."
        }
    }
}

// MARK: - CastAudioStreamer

/// Captures Kaset's audio, encodes it, and serves it to the Cast device.
///
/// The pipeline is deliberately independent from YouTube: the audio is captured after WebKit has
/// decoded it, so DRM-protected playback, podcasts, and ads all cast exactly as they play locally.
@MainActor
final class CastAudioStreamer {
    private let server: LocalAudioStreamServer
    private var tap: AudioProcessTap?
    private var encoder: AACStreamEncoder?
    private var consumerTask: Task<Void, Never>?

    init(server: LocalAudioStreamServer = LocalAudioStreamServer()) {
        self.server = server
    }

    /// Path the receiver requests, e.g. `/kaset-cast.aac`.
    var streamPath: String {
        self.server.streamPath
    }

    /// Whether the receiver is currently reading the stream.
    var isReceiverConnected: Bool {
        self.server.streamingClientCount > 0
    }

    /// Called when the receiver connects to or leaves the stream.
    var onReceiverConnectionChanged: ((Bool) -> Void)?

    /// Starts the pipeline and returns the URL the Cast device should play.
    ///
    /// - Parameter preferredLocalAddress: Address the control connection is using, which is the one
    ///   the device can dial back. Falls back to subnet matching when it is unavailable.
    func start(deviceHost: String, preferredLocalAddress: String? = nil) async throws -> URL {
        self.server.onStreamingClientCountChanged = { [weak self] count in
            self?.onReceiverConnectionChanged?(count > 0)
        }

        let port = try await self.server.start()

        let candidates = CastStreamAddress.localIPv4Addresses()
        guard let localAddress = preferredLocalAddress
            ?? CastStreamAddress.bestAddress(forDeviceHost: deviceHost, candidates: candidates)
        else {
            self.server.stop()
            throw CastAudioStreamerError.noLocalAddress
        }

        DiagnosticsLogger.cast.info(
            "Serving the stream from \(localAddress) (local addresses: \(candidates.map(\.address).joined(separator: ", ")))"
        )

        // WebKit plays audio from helper processes the app spawns, so the tap has to cover the app
        // and its children.
        let processIDs = [getpid()] + ProcessTree.descendantProcessIDs(of: getpid())

        let tap = try AudioProcessTap(processIDs: processIDs)
        let encoder = try AACStreamEncoder(anyFormat: tap.format)

        self.tap = tap
        self.encoder = encoder

        let audioStream = tap.start()

        self.consumerTask = Task { [weak self] in
            for await buffer in audioStream {
                guard let self, let encoder = self.encoder else { return }

                do {
                    let encoded = try encoder.encode(buffer)
                    guard !encoded.isEmpty else { continue }
                    self.server.enqueue(encoded)
                } catch {
                    DiagnosticsLogger.cast.error("Audio encoding failed: \(error.localizedDescription)")
                }
            }
        }

        guard let url = URL(string: "http://\(localAddress):\(port)\(self.server.streamPath)") else {
            throw CastAudioStreamerError.noLocalAddress
        }

        DiagnosticsLogger.cast.info("Audio stream available at \(url.absoluteString)")
        return url
    }

    /// Stops capture, encoding, and serving.
    func stop() {
        self.consumerTask?.cancel()
        self.consumerTask = nil

        self.tap?.stop()
        self.tap = nil
        self.encoder = nil

        self.server.stop()
    }
}
