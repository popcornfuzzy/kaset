import Foundation
import Testing
@testable import Kaset

/// The CASTV2 conversation that puts the Default Media Receiver on Kaset's stream.
@Suite(.tags(.service))
@MainActor
struct CastReceiverSessionTests {
    // MARK: - Handshake

    @Test("Starting the session opens a connection and asks for the receiver status")
    func startSendsConnectAndStatusRequest() {
        let channel = FakeCastChannel()
        let session = CastReceiverSession(channel: channel)

        session.start()

        let connections = channel.messages(in: CastNamespace.connection)
        #expect(connections.count == 1)
        #expect(connections[0].destinationId == CastEndpoint.platformReceiver)
        #expect(connections[0].payload.payloadUtf8 == CastPayloadBuilder.connect())

        let receiverMessages = channel.messages(in: CastNamespace.receiver)
        #expect(receiverMessages.count == 1)
        #expect(receiverMessages[0].payload.payloadUtf8?.contains("GET_STATUS") == true)
        #expect(session.currentPhase == .connecting)

        session.stop()
    }

    @Test("An idle device is asked to launch the receiver once")
    func launchesReceiverOnceWhenIdle() {
        let channel = FakeCastChannel()
        let session = CastReceiverSession(channel: channel)
        session.start()
        channel.clear()

        channel.deliver(payload: Self.idleReceiverStatus, namespace: CastNamespace.receiver)
        #expect(session.currentPhase == .launching)

        let launches = channel.messages(in: CastNamespace.receiver).filter {
            $0.payload.payloadUtf8?.contains("\"LAUNCH\"") == true
        }
        #expect(launches.count == 1)
        #expect(launches[0].payload.payloadUtf8?.contains(CastEndpoint.defaultMediaReceiverAppID) == true)

        // A second idle status must not trigger another launch.
        channel.deliver(payload: Self.idleReceiverStatus, namespace: CastNamespace.receiver)
        let relaunches = channel.messages(in: CastNamespace.receiver).filter {
            $0.payload.payloadUtf8?.contains("\"LAUNCH\"") == true
        }
        #expect(relaunches.count == 1)

        session.stop()
    }

    @Test("A running receiver is attached to instead of launched")
    func attachesToRunningReceiver() {
        let channel = FakeCastChannel()
        let session = CastReceiverSession(channel: channel)
        session.start()
        channel.clear()

        channel.deliver(payload: Self.runningReceiverStatus, namespace: CastNamespace.receiver)

        #expect(session.currentPhase == .buffering)

        let connections = channel.messages(in: CastNamespace.connection)
        #expect(connections.count == 1)
        #expect(connections[0].destinationId == "web-5")
        #expect(connections[0].payload.payloadUtf8 == CastPayloadBuilder.connect())

        #expect(!channel.messages(in: CastNamespace.receiver).contains {
            $0.payload.payloadUtf8?.contains("\"LAUNCH\"") == true
        })

        session.stop()
    }

    // MARK: - Media Loading

    @Test("The stream is handed over once the receiver is attached")
    func loadsStreamAfterAttach() throws {
        let channel = FakeCastChannel()
        let session = CastReceiverSession(channel: channel)
        session.start()
        channel.clear()

        // The stream URL is known before the receiver is running.
        session.prepareStream(url: "http://192.168.1.10:51000/kaset-cast.aac")
        #expect(channel.messages(in: CastNamespace.media).isEmpty)

        channel.deliver(payload: Self.runningReceiverStatus, namespace: CastNamespace.receiver)

        let loads = channel.messages(in: CastNamespace.media)
        #expect(loads.count == 1)
        #expect(loads[0].destinationId == "web-5")

        let payload = try #require(loads[0].payload.payloadUtf8)
        let object = try #require(Self.json(payload))
        let media = try #require(object["media"] as? [String: Any])
        #expect(object["type"] as? String == "LOAD")
        #expect(media["contentId"] as? String == "http://192.168.1.10:51000/kaset-cast.aac")
        #expect(media["contentType"] as? String == "audio/aac")
        #expect(media["streamType"] as? String == "LIVE")

        session.stop()
    }

    @Test("The stream is loaded only once")
    func loadsStreamOnlyOnce() {
        let channel = FakeCastChannel()
        let session = CastReceiverSession(channel: channel)
        session.start()
        channel.deliver(payload: Self.runningReceiverStatus, namespace: CastNamespace.receiver)
        channel.clear()

        session.prepareStream(url: "http://192.168.1.10:51000/kaset-cast.aac")
        session.prepareStream(url: "http://192.168.1.10:51000/kaset-cast.aac")

        #expect(channel.messages(in: CastNamespace.media).count == 1)

        session.stop()
    }

    @Test("Preparing a stream while disconnected sends nothing")
    func preparingStreamWithoutReceiverSendsNothing() {
        let channel = FakeCastChannel()
        let session = CastReceiverSession(channel: channel)
        session.start()
        channel.clear()

        session.prepareStream(url: "http://192.168.1.10:51000/kaset-cast.aac")

        #expect(channel.messages(in: CastNamespace.media).isEmpty)

        session.stop()
    }

    // MARK: - Playback Status

    @Test("A playing media session moves the session to playing")
    func playingStatusUpdatesPhase() {
        let channel = FakeCastChannel()
        let session = CastReceiverSession(channel: channel)
        session.start()
        channel.deliver(payload: Self.runningReceiverStatus, namespace: CastNamespace.receiver)

        channel.deliver(payload: Self.playingMediaStatus, namespace: CastNamespace.media)

        #expect(session.currentPhase == .playing(mediaSessionID: 12))

        session.stop()
    }

    @Test("An errored media session fails the session")
    func erroredMediaSessionFails() {
        let channel = FakeCastChannel()
        let session = CastReceiverSession(channel: channel)
        session.start()
        channel.deliver(payload: Self.runningReceiverStatus, namespace: CastNamespace.receiver)

        channel.deliver(payload: Self.erroredMediaStatus, namespace: CastNamespace.media)

        guard case .failed = session.currentPhase else {
            Issue.record("Expected the session to fail, got \(session.currentPhase)")
            return
        }

        session.stop()
    }

    @Test("A launch failure fails the session")
    func launchErrorFails() {
        let channel = FakeCastChannel()
        let session = CastReceiverSession(channel: channel)
        session.start()

        channel.deliver(payload: #"{"type":"LAUNCH_ERROR"}"#, namespace: CastNamespace.receiver)

        guard case .failed = session.currentPhase else {
            Issue.record("Expected the session to fail, got \(session.currentPhase)")
            return
        }

        session.stop()
    }

    @Test("Phase changes are reported to the observer")
    func reportsPhaseChanges() {
        let channel = FakeCastChannel()
        let session = CastReceiverSession(channel: channel)

        var phases: [CastReceiverSession.Phase] = []
        session.onPhaseChanged = { phases.append($0) }

        session.start()
        channel.deliver(payload: Self.runningReceiverStatus, namespace: CastNamespace.receiver)
        channel.deliver(payload: Self.playingMediaStatus, namespace: CastNamespace.media)

        #expect(phases == [.buffering, .playing(mediaSessionID: 12)])

        session.stop()
    }

    // MARK: - Heartbeat

    @Test("A heartbeat ping is answered with a pong")
    func answersHeartbeatPing() {
        let channel = FakeCastChannel()
        let session = CastReceiverSession(channel: channel)
        session.start()
        channel.clear()

        channel.deliver(
            payload: #"{"type":"PING"}"#,
            namespace: CastNamespace.heartbeat,
            from: CastEndpoint.platformReceiver
        )

        let heartbeats = channel.messages(in: CastNamespace.heartbeat)
        #expect(heartbeats.count == 1)
        #expect(heartbeats[0].destinationId == CastEndpoint.platformReceiver)
        #expect(heartbeats[0].payload.payloadUtf8 == CastPayloadBuilder.pong())

        session.stop()
    }

    // MARK: - Stopping

    @Test("Stopping the session tells the device to stop and closes the channel")
    func stopSendsStopCommands() {
        let channel = FakeCastChannel()
        let session = CastReceiverSession(channel: channel)
        session.start()
        channel.deliver(payload: Self.runningReceiverStatus, namespace: CastNamespace.receiver)
        channel.deliver(payload: Self.playingMediaStatus, namespace: CastNamespace.media)
        channel.clear()

        session.stop()

        let mediaMessages = channel.messages(in: CastNamespace.media)
        #expect(mediaMessages.count == 1)
        #expect(mediaMessages[0].payload.payloadUtf8?.contains("\"STOP\"") == true)
        #expect(mediaMessages[0].payload.payloadUtf8?.contains("\"mediaSessionId\":12") == true)
        #expect(mediaMessages[0].destinationId == "web-5")

        let receiverMessages = channel.messages(in: CastNamespace.receiver)
        #expect(receiverMessages.count == 1)
        #expect(receiverMessages[0].payload.payloadUtf8?.contains("\"STOP\"") == true)

        #expect(channel.isClosed)
        #expect(session.currentPhase == .stopped)
    }

    @Test("Stopping without a media session still stops the receiver")
    func stopWithoutMediaSession() {
        let channel = FakeCastChannel()
        let session = CastReceiverSession(channel: channel)
        session.start()
        channel.clear()

        session.stop()

        #expect(channel.messages(in: CastNamespace.media).isEmpty)
        #expect(channel.messages(in: CastNamespace.receiver).count == 1)
        #expect(channel.isClosed)
    }

    @Test("A channel that closes on its own fails the session")
    func channelCloseFailsSession() {
        let channel = FakeCastChannel()
        let session = CastReceiverSession(channel: channel)
        session.start()

        channel.simulateClose(error: CastConnection.ConnectionError.failed("socket closed"))

        guard case .failed = session.currentPhase else {
            Issue.record("Expected the session to fail, got \(session.currentPhase)")
            return
        }
    }

    // MARK: - Fixtures

    private static let idleReceiverStatus = #"{"type":"RECEIVER_STATUS","status":{"applications":[]}}"#

    private static let runningReceiverStatus = """
    {"type":"RECEIVER_STATUS","status":{"applications":[\
    {"appId":"CC1AD845","displayName":"Default Media Receiver","transportId":"web-5","sessionId":"s-1"}]}}
    """

    private static let playingMediaStatus = #"{"type":"MEDIA_STATUS","status":[{"mediaSessionId":12,"playerState":"PLAYING"}]}"#

    private static let erroredMediaStatus = #"{"type":"MEDIA_STATUS","status":[{"mediaSessionId":12,"playerState":"IDLE","idleReason":"ERROR"}]}"#

    private static func json(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

// MARK: - FakeCastChannel

/// Records what a session sends and lets tests inject device responses.
@MainActor
private final class FakeCastChannel: CastMessageChannel {
    var onMessage: ((CastMessage) -> Void)?
    var onClose: ((Swift.Error?) -> Void)?

    private(set) var sent: [CastMessage] = []
    private(set) var isClosed = false

    func send(_ message: CastMessage) {
        self.sent.append(message)
    }

    func close() {
        self.isClosed = true
    }

    func messages(in namespace: String) -> [CastMessage] {
        self.sent.filter { $0.namespace == namespace }
    }

    func clear() {
        self.sent.removeAll()
    }

    func deliver(
        payload: String,
        namespace: String,
        from sourceID: String = CastEndpoint.platformReceiver
    ) {
        self.onMessage?(
            CastMessage(
                sourceId: sourceID,
                destinationId: CastEndpoint.sender,
                namespace: namespace,
                payload: .string(payload)
            )
        )
    }

    func simulateClose(error: Swift.Error?) {
        self.onClose?(error)
    }
}
