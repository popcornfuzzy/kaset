import Foundation
import Testing
@testable import Kaset

/// Cast payload construction and status decoding.
@Suite(.tags(.service))
struct CastProtocolTests {
    // MARK: - Payload Builders

    @Test("Connect and close payloads use the connection namespace shape")
    func connectionPayloads() {
        #expect(CastPayloadBuilder.connect() == "{\"type\":\"CONNECT\"}")
        #expect(CastPayloadBuilder.close() == "{\"type\":\"CLOSE\"}")
    }

    @Test("Heartbeat payloads use the documented message types")
    func heartbeatPayloads() {
        #expect(CastPayloadBuilder.ping() == "{\"type\":\"PING\"}")
        #expect(CastPayloadBuilder.pong() == "{\"type\":\"PONG\"}")
    }

    @Test("Status request carries a request identifier")
    func statusRequestPayload() {
        #expect(CastPayloadBuilder.getStatus(requestID: 3) == "{\"requestId\":3,\"type\":\"GET_STATUS\"}")
    }

    @Test("Launch payload targets the default media receiver")
    func launchPayload() throws {
        let payload = CastPayloadBuilder.launch(appID: CastEndpoint.defaultMediaReceiverAppID, requestID: 1)
        let object = try #require(self.json(payload))

        #expect(object["type"] as? String == "LAUNCH")
        #expect(object["appId"] as? String == "CC1AD845")
        #expect(object["requestId"] as? Int == 1)
    }

    @Test("Load payload describes a live audio stream")
    func loadPayload() throws {
        let payload = CastPayloadBuilder.load(
            contentID: "http://192.168.1.10:51000/kaset-cast.aac",
            contentType: "audio/aac",
            requestID: 2
        )
        let object = try #require(self.json(payload))
        let media = try #require(object["media"] as? [String: Any])

        #expect(object["type"] as? String == "LOAD")
        #expect(object["autoplay"] as? Bool == true)
        #expect(media["contentId"] as? String == "http://192.168.1.10:51000/kaset-cast.aac")
        #expect(media["contentType"] as? String == "audio/aac")
        #expect(media["streamType"] as? String == "LIVE")
    }

    @Test("Volume payload clamps the level into range")
    func volumePayloadClamps() throws {
        let tooHigh = try #require(self.json(CastPayloadBuilder.setVolume(level: 4.2, requestID: 1)))
        let tooLow = try #require(self.json(CastPayloadBuilder.setVolume(level: -3, requestID: 1)))
        let normal = try #require(self.json(CastPayloadBuilder.setVolume(level: 0.4, requestID: 1)))

        #expect((tooHigh["volume"] as? [String: Any])?["level"] as? Double == 1)
        #expect((tooLow["volume"] as? [String: Any])?["level"] as? Double == 0)
        #expect((normal["volume"] as? [String: Any])?["level"] as? Double == 0.4)
    }

    @Test("Media commands carry the media session identifier")
    func mediaCommandPayloads() throws {
        for payload in [
            CastPayloadBuilder.mediaPlay(sessionID: 7, requestID: 1),
            CastPayloadBuilder.mediaPause(sessionID: 7, requestID: 1),
            CastPayloadBuilder.mediaStop(sessionID: 7, requestID: 1),
        ] {
            let object = try #require(self.json(payload))
            #expect(object["mediaSessionId"] as? Int == 7)
        }
    }

    // MARK: - Endpoints

    @Test("Cast endpoints match the protocol constants")
    func endpointConstants() {
        #expect(CastEndpoint.platformReceiver == "receiver-0")
        #expect(CastEndpoint.sender == "sender-0")
        #expect(CastEndpoint.defaultMediaReceiverAppID == "CC1AD845")
    }

    @Test("Cast namespaces match the protocol constants")
    func namespaceConstants() {
        #expect(CastNamespace.connection == "urn:x-cast:com.google.cast.tp.connection")
        #expect(CastNamespace.heartbeat == "urn:x-cast:com.google.cast.tp.heartbeat")
        #expect(CastNamespace.receiver == "urn:x-cast:com.google.cast.receiver")
        #expect(CastNamespace.media == "urn:x-cast:com.google.cast.media")
    }

    // MARK: - Status Decoding

    @Test("Decodes a receiver status with a running application")
    func decodesReceiverStatusWithApplication() throws {
        let payload = """
        {"type":"RECEIVER_STATUS","requestId":0,"status":{"applications":[\
        {"appId":"CC1AD845","displayName":"Default Media Receiver","transportId":"web-5","sessionId":"s-1"}],\
        "volume":{"level":0.35,"muted":false}}}
        """

        let decoded = try CastStatusDecoder.decode(payload: payload)
        guard case let .receiver(status) = decoded else {
            Issue.record("Expected a receiver status")
            return
        }

        #expect(status.applications.count == 1)
        #expect(status.application(appID: "CC1AD845")?.transportID == "web-5")
        #expect(status.application(appID: "CC1AD845")?.displayName == "Default Media Receiver")
        #expect(status.volumeLevel == 0.35)
        #expect(status.volumeMuted == false)
        #expect(status.isIdle == false)
    }

    @Test("Decodes an idle receiver status")
    func decodesIdleReceiverStatus() throws {
        let payload = #"{"type":"RECEIVER_STATUS","status":{"applications":[],"volume":{"level":1}}}"#

        let decoded = try CastStatusDecoder.decode(payload: payload)
        guard case let .receiver(status) = decoded else {
            Issue.record("Expected a receiver status")
            return
        }

        #expect(status.isIdle)
        #expect(status.application(appID: "CC1AD845") == nil)
    }

    @Test("Receiver status without a volume block decodes")
    func decodesReceiverStatusWithoutVolume() throws {
        let payload = #"{"type":"RECEIVER_STATUS","status":{"applications":[]}}"#

        let decoded = try CastStatusDecoder.decode(payload: payload)
        guard case let .receiver(status) = decoded else {
            Issue.record("Expected a receiver status")
            return
        }

        #expect(status.volumeLevel == nil)
        #expect(status.volumeMuted == nil)
    }

    @Test("Applications without a transport identifier are dropped")
    func dropsApplicationsWithoutTransportID() throws {
        let payload = """
        {"type":"RECEIVER_STATUS","status":{"applications":[{"appId":"CC1AD845","displayName":"Broken"}]}}
        """

        let decoded = try CastStatusDecoder.decode(payload: payload)
        guard case let .receiver(status) = decoded else {
            Issue.record("Expected a receiver status")
            return
        }

        #expect(status.applications.isEmpty)
    }

    @Test("Decodes a playing media status")
    func decodesMediaStatus() throws {
        let payload = """
        {"type":"MEDIA_STATUS","status":[{"mediaSessionId":12,"playerState":"PLAYING","currentTime":0}]}
        """

        let decoded = try CastStatusDecoder.decode(payload: payload)
        guard case let .media(entries) = decoded else {
            Issue.record("Expected a media status")
            return
        }

        #expect(entries.count == 1)
        #expect(entries[0].mediaSessionID == 12)
        #expect(entries[0].playerState == "PLAYING")
        #expect(entries[0].isIdle == false)
    }

    @Test("Decodes an idle media status with an error reason")
    func decodesErroredMediaStatus() throws {
        let payload = #"{"type":"MEDIA_STATUS","status":[{"mediaSessionId":4,"playerState":"IDLE","idleReason":"ERROR"}]}"#

        let decoded = try CastStatusDecoder.decode(payload: payload)
        guard case let .media(entries) = decoded else {
            Issue.record("Expected a media status")
            return
        }

        #expect(entries[0].isIdle)
        #expect(entries[0].idleReason == "ERROR")
    }

    @Test("Unknown message types are reported as unsupported")
    func reportsUnsupportedTypes() throws {
        let decoded = try CastStatusDecoder.decode(payload: #"{"type":"LAUNCH_ERROR"}"#)
        #expect(decoded == .unsupported(type: "LAUNCH_ERROR"))
    }

    @Test("Malformed status payloads throw")
    func malformedPayloadsThrow() {
        #expect(throws: CastStatusError.self) {
            try CastStatusDecoder.decode(payload: "not json")
        }
        #expect(throws: CastStatusError.self) {
            try CastStatusDecoder.decode(payload: "[]")
        }
        #expect(throws: CastStatusError.self) {
            try CastStatusDecoder.decode(payload: #"{"requestId":1}"#)
        }
    }

    // MARK: - Helpers

    private func json(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
