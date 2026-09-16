import Foundation

// MARK: - CastReceiverSession

/// Drives the CASTV2 conversation that puts the Default Media Receiver on Kaset's stream.
///
/// The sequence mirrors what any Cast sender does: open a virtual connection to the platform
/// receiver, launch the target application (or attach to the instance already running), open a
/// virtual connection to that application, then hand it the media URL.
@MainActor
final class CastReceiverSession {
    /// Where the session currently stands.
    enum Phase: Equatable {
        /// Connected, waiting for the platform receiver's status.
        case connecting

        /// Asked the device to launch the receiver application.
        case launching

        /// Attached to the receiver application and streaming audio to it.
        case buffering

        /// The receiver reports playback.
        case playing(mediaSessionID: Int?)

        /// The session ended on purpose.
        case stopped

        /// The session failed.
        case failed(String)
    }

    private let channel: CastMessageChannel
    private let appID: String
    private var requestID = 0
    private var phase: Phase = .connecting {
        didSet {
            guard self.phase != oldValue else { return }
            self.onPhaseChanged?(self.phase)
        }
    }

    private var mediaTransportID: String?
    private var mediaSessionID: Int?
    private var pendingStreamURL: String?
    private var hasSentLoad = false
    private var didRequestLaunch = false

    private var heartbeatTask: Task<Void, Never>?

    /// Called whenever the session phase changes.
    var onPhaseChanged: ((Phase) -> Void)?

    init(channel: CastMessageChannel, appID: String = CastEndpoint.defaultMediaReceiverAppID) {
        self.channel = channel
        self.appID = appID
    }

    deinit {
        // The heartbeat task holds only a weak reference to the session, so it has to be stopped
        // even when the session is released without an explicit ``stop()``.
        self.heartbeatTask?.cancel()
    }

    /// Current session phase.
    var currentPhase: Phase {
        self.phase
    }

    /// Begins the handshake.
    func start() {
        self.channel.onMessage = { [weak self] message in
            self?.handle(message: message)
        }

        self.channel.onClose = { [weak self] error in
            guard let self else { return }
            if case .stopped = self.phase {
                return
            }
            self.phase = error.map { .failed($0.localizedDescription) } ?? .stopped
        }

        self.channel.send(
            CastMessage(
                sourceId: CastEndpoint.sender,
                destinationId: CastEndpoint.platformReceiver,
                namespace: CastNamespace.connection,
                payload: .string(CastPayloadBuilder.connect())
            )
        )

        self.channel.send(
            CastMessage(
                sourceId: CastEndpoint.sender,
                destinationId: CastEndpoint.platformReceiver,
                namespace: CastNamespace.receiver,
                payload: .string(CastPayloadBuilder.getStatus(requestID: self.nextRequestID()))
            )
        )

        self.startHeartbeat()
    }

    /// Provides the stream URL to hand to the receiver.
    ///
    /// The URL may arrive before the receiver application is running; it is sent as soon as the
    /// application is attached.
    func prepareStream(url: String) {
        self.pendingStreamURL = url
        self.sendLoadIfPossible()
    }

    /// Stops the receiver application and closes the channel.
    func stop() {
        self.heartbeatTask?.cancel()
        self.heartbeatTask = nil

        if let mediaSessionID {
            self.channel.send(
                CastMessage(
                    sourceId: CastEndpoint.sender,
                    destinationId: self.mediaTransportID ?? CastEndpoint.platformReceiver,
                    namespace: CastNamespace.media,
                    payload: .string(CastPayloadBuilder.mediaStop(sessionID: mediaSessionID, requestID: self.nextRequestID()))
                )
            )
        }

        self.channel.send(
            CastMessage(
                sourceId: CastEndpoint.sender,
                destinationId: CastEndpoint.platformReceiver,
                namespace: CastNamespace.receiver,
                payload: .string(CastPayloadBuilder.stopReceiver(requestID: self.nextRequestID()))
            )
        )

        self.phase = .stopped
        self.channel.close()
    }

    // MARK: - Message Handling

    private func handle(message: CastMessage) {
        guard let payload = message.payload.payloadUtf8 else { return }

        switch message.namespace {
        case CastNamespace.heartbeat:
            if payload.contains("PING") {
                self.channel.send(
                    CastMessage(
                        sourceId: CastEndpoint.sender,
                        destinationId: message.sourceId,
                        namespace: CastNamespace.heartbeat,
                        payload: .string(CastPayloadBuilder.pong())
                    )
                )
            }

        case CastNamespace.receiver:
            self.handleReceiverPayload(payload)

        case CastNamespace.media:
            self.handleMediaPayload(payload)

        default:
            break
        }
    }

    private func handleReceiverPayload(_ payload: String) {
        guard let status = try? CastStatusDecoder.decode(payload: payload) else {
            DiagnosticsLogger.cast.debug("Ignoring unreadable receiver payload")
            return
        }

        switch status {
        case let .receiver(receiverStatus):
            self.handleReceiverStatus(receiverStatus)

        case let .unsupported(type):
            if type == "LAUNCH_ERROR" {
                self.phase = .failed("The Cast device refused to launch its media receiver.")
            }

        case .media:
            break
        }
    }

    private func handleReceiverStatus(_ status: CastReceiverStatus) {
        guard let application = status.application(appID: self.appID) else {
            if case .stopped = self.phase {
                return
            }

            // The receiver is not running yet: ask the device to launch it once.
            if !self.didRequestLaunch {
                self.didRequestLaunch = true
                self.phase = .launching
                self.channel.send(
                    CastMessage(
                        sourceId: CastEndpoint.sender,
                        destinationId: CastEndpoint.platformReceiver,
                        namespace: CastNamespace.receiver,
                        payload: .string(CastPayloadBuilder.launch(appID: self.appID, requestID: self.nextRequestID()))
                    )
                )
            }
            return
        }

        guard self.mediaTransportID != application.transportID else { return }

        // Attach to the running receiver application, which is what application-scoped media
        // messages have to be addressed to.
        self.mediaTransportID = application.transportID
        self.channel.send(
            CastMessage(
                sourceId: CastEndpoint.sender,
                destinationId: application.transportID,
                namespace: CastNamespace.connection,
                payload: .string(CastPayloadBuilder.connect())
            )
        )

        if case .stopped = self.phase {
            return
        }
        self.phase = .buffering
        self.sendLoadIfPossible()
    }

    private func handleMediaPayload(_ payload: String) {
        guard let status = try? CastStatusDecoder.decode(payload: payload) else { return }

        guard case let .media(entries) = status, let entry = entries.first else { return }

        if let sessionID = entry.mediaSessionID {
            self.mediaSessionID = sessionID
        }

        if entry.isIdle, entry.idleReason == "ERROR" {
            self.phase = .failed("The Cast device could not play the audio stream.")
            return
        }

        if entry.playerState?.uppercased() == "PLAYING" {
            self.phase = .playing(mediaSessionID: self.mediaSessionID)
        }
    }

    // MARK: - Helpers

    private func sendLoadIfPossible() {
        guard let streamURL = self.pendingStreamURL, !self.hasSentLoad, let transportID = self.mediaTransportID else {
            return
        }

        self.hasSentLoad = true

        self.channel.send(
            CastMessage(
                sourceId: CastEndpoint.sender,
                destinationId: transportID,
                namespace: CastNamespace.media,
                payload: .string(
                    CastPayloadBuilder.load(
                        contentID: streamURL,
                        contentType: "audio/aac",
                        requestID: self.nextRequestID()
                    )
                )
            )
        )

        DiagnosticsLogger.cast.info("Handed the audio stream to the Cast device")
    }

    private func startHeartbeat() {
        self.heartbeatTask?.cancel()

        self.heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: CastEndpoint.heartbeatInterval)
                guard !Task.isCancelled, let self else { return }

                self.channel.send(
                    CastMessage(
                        sourceId: CastEndpoint.sender,
                        destinationId: CastEndpoint.platformReceiver,
                        namespace: CastNamespace.heartbeat,
                        payload: .string(CastPayloadBuilder.ping())
                    )
                )
            }
        }
    }

    private func nextRequestID() -> Int {
        self.requestID += 1
        return self.requestID
    }
}
