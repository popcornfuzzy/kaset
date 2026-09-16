import Foundation

// MARK: - Namespaces

/// The CASTV2 namespaces Kaset talks to.
enum CastNamespace {
    /// Virtual-connection namespace: opens and closes the transport to an endpoint.
    static let connection = "urn:x-cast:com.google.cast.tp.connection"

    /// Heartbeat namespace: Cast devices drop connections that stop answering `PING`.
    static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"

    /// Receiver namespace: application launch and volume control.
    static let receiver = "urn:x-cast:com.google.cast.receiver"

    /// Media namespace: playback commands sent to a running receiver application.
    static let media = "urn:x-cast:com.google.cast.media"
}

// MARK: - Endpoints

/// Well-known Cast endpoint identifiers and application identifiers.
enum CastEndpoint {
    /// Identifier of the platform receiver running on the device itself.
    static let platformReceiver = "receiver-0"

    /// Identifier used by Cast senders such as Kaset.
    static let sender = "sender-0"

    /// Application identifier of the built-in Default Media Receiver.
    ///
    /// The default receiver plays a media URL the sender provides, which is what Kaset uses: it is
    /// installed on every Cast device and needs no registration.
    static let defaultMediaReceiverAppID = "CC1AD845"

    /// How often Kaset pings the device to keep the connection alive.
    static let heartbeatInterval: Duration = .seconds(5)
}

// MARK: - Payloads

/// Builders for the JSON payloads Cast senders exchange with devices.
///
/// All payloads are encoded with sorted keys so that tests can assert exact bytes.
enum CastPayloadBuilder {
    /// Errors thrown when a payload cannot be encoded.
    enum Error: Swift.Error {
        case encodingFailed(String)
    }

    /// `{"type":"CONNECT"}`
    static func connect() -> String {
        self.encode(["type": "CONNECT"])
    }

    /// `{"type":"CLOSE"}`
    static func close() -> String {
        self.encode(["type": "CLOSE"])
    }

    /// `{"type":"PING"}`
    static func ping() -> String {
        self.encode(["type": "PING"])
    }

    /// `{"type":"PONG"}`
    static func pong() -> String {
        self.encode(["type": "PONG"])
    }

    /// `{"type":"GET_STATUS","requestId":…}`
    static func getStatus(requestID: Int) -> String {
        self.encode(["type": "GET_STATUS", "requestId": requestID])
    }

    /// `{"type":"LAUNCH","appId":"CC1AD845","requestId":…}`
    static func launch(appID: String, requestID: Int) -> String {
        self.encode(["type": "LAUNCH", "appId": appID, "requestId": requestID])
    }

    /// `{"type":"SET_VOLUME","volume":{"level":…},"requestId":…}`
    static func setVolume(level: Double, requestID: Int) -> String {
        self.encode([
            "type": "SET_VOLUME",
            "volume": ["level": self.clamp(level)],
            "requestId": requestID,
        ])
    }

    /// `{"type":"STOP","requestId":…}`
    static func stopReceiver(requestID: Int) -> String {
        self.encode(["type": "STOP", "requestId": requestID])
    }

    /// `{"type":"LOAD","requestId":…,"autoplay":true,"media":{…}}`
    ///
    /// - Parameters:
    ///   - contentID: Absolute URL the receiver should play. This points at Kaset's local stream.
    ///   - contentType: MIME type of the stream, e.g. `audio/aac`.
    ///   - requestID: Monotonically increasing request identifier.
    static func load(contentID: String, contentType: String, requestID: Int) -> String {
        self.encode([
            "type": "LOAD",
            "requestId": requestID,
            "autoplay": true,
            "media": [
                "contentId": contentID,
                "contentType": contentType,
                "streamType": "LIVE",
            ],
        ])
    }

    /// `{"type":"PAUSE","requestId":…,"mediaSessionId":…}`
    static func mediaPause(sessionID: Int, requestID: Int) -> String {
        self.mediaCommand("PAUSE", sessionID: sessionID, requestID: requestID)
    }

    /// `{"type":"PLAY","requestId":…,"mediaSessionId":…}`
    static func mediaPlay(sessionID: Int, requestID: Int) -> String {
        self.mediaCommand("PLAY", sessionID: sessionID, requestID: requestID)
    }

    /// `{"type":"STOP","requestId":…,"mediaSessionId":…}`
    static func mediaStop(sessionID: Int, requestID: Int) -> String {
        self.mediaCommand("STOP", sessionID: sessionID, requestID: requestID)
    }

    /// `{"type":"GET_STATUS","requestId":…,"mediaSessionId":…}`
    static func mediaGetStatus(sessionID: Int, requestID: Int) -> String {
        self.mediaCommand("GET_STATUS", sessionID: sessionID, requestID: requestID)
    }

    /// Encodes a dictionary as compact, key-sorted JSON.
    private static func encode(_ object: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            // Every payload here is a JSON-safe literal, so this is unreachable in practice.
            DiagnosticsLogger.cast.error("Failed to encode Cast payload")
            return "{}"
        }
        return json
    }

    /// Builds a media-namespace command payload.
    private static func mediaCommand(_ type: String, sessionID: Int, requestID: Int) -> String {
        self.encode([
            "type": type,
            "requestId": requestID,
            "mediaSessionId": sessionID,
        ])
    }

    /// Constrains a volume level to the range Cast accepts.
    private static func clamp(_ level: Double) -> Double {
        min(max(level, 0), 1)
    }
}

// MARK: - Status

/// A receiver application currently running on a device.
struct CastApplicationStatus: Equatable, Sendable {
    /// Application identifier, e.g. `CC1AD845` for the Default Media Receiver.
    let appID: String

    /// Display name reported by the device.
    let displayName: String?

    /// Transport identifier used as the destination for application-scoped messages.
    let transportID: String

    /// Session identifier of the running application.
    let sessionID: String?
}

/// Decoded state of the platform receiver.
struct CastReceiverStatus: Equatable, Sendable {
    /// Applications the device reports as running.
    let applications: [CastApplicationStatus]

    /// Receiver volume level (`0…1`), when reported.
    let volumeLevel: Double?

    /// Whether the receiver is muted, when reported.
    let volumeMuted: Bool?

    /// Whether no application is running on the device.
    var isIdle: Bool {
        self.applications.isEmpty
    }

    /// Finds a running application by identifier.
    func application(appID: String) -> CastApplicationStatus? {
        self.applications.first { $0.appID == appID }
    }
}

/// Decoded state of a media session.
struct CastMediaStatus: Equatable, Sendable {
    /// Session identifier needed for follow-up media commands.
    let mediaSessionID: Int?

    /// `PLAYING`, `PAUSED`, `BUFFERING`, or `IDLE` as reported by the receiver.
    let playerState: String?

    /// Reason the session went idle, e.g. `ERROR` or `FINISHED`.
    let idleReason: String?

    /// Whether the receiver reported a failed session.
    var isIdle: Bool {
        self.playerState?.uppercased() == "IDLE"
    }
}

/// A decoded message from the receiver or media namespace.
enum CastStatusMessage: Equatable, Sendable {
    /// A `RECEIVER_STATUS` message.
    case receiver(CastReceiverStatus)

    /// One or more `MEDIA_STATUS` entries.
    case media([CastMediaStatus])

    /// A message type Kaset does not act on, e.g. `INVALID_REQUEST`.
    case unsupported(type: String)
}

/// Errors thrown while decoding Cast status payloads.
enum CastStatusError: Error, Equatable {
    /// The payload was not valid JSON, or was not a JSON object.
    case invalidPayload

    /// The payload had no `type` field.
    case missingType
}

// MARK: - Status Decoding

/// Decodes receiver and media status payloads.
enum CastStatusDecoder {
    /// Decodes a status payload received in the receiver or media namespace.
    static func decode(payload: String) throws -> CastStatusMessage {
        guard let data = payload.data(using: .utf8) else {
            throw CastStatusError.invalidPayload
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CastStatusError.invalidPayload
        }

        guard let type = object["type"] as? String else {
            throw CastStatusError.missingType
        }

        switch type {
        case "RECEIVER_STATUS":
            return .receiver(self.receiverStatus(from: object))

        case "MEDIA_STATUS":
            let entries = object["status"] as? [[String: Any]] ?? []
            return .media(entries.prefix(1).map(self.mediaStatus(from:)))

        case "LAUNCH_ERROR", "LOAD_FAILED", "INVALID_REQUEST", "INVALID_MEDIA_SESSION_ID":
            return .unsupported(type: type)

        default:
            return .unsupported(type: type)
        }
    }

    /// Reads a receiver status object.
    private static func receiverStatus(from object: [String: Any]) -> CastReceiverStatus {
        let status = object["status"] as? [String: Any] ?? [:]
        let applications = (status["applications"] as? [[String: Any]] ?? []).compactMap { entry -> CastApplicationStatus? in
            guard
                let appID = entry["appId"] as? String,
                let transportID = entry["transportId"] as? String
            else { return nil }

            return CastApplicationStatus(
                appID: appID,
                displayName: entry["displayName"] as? String,
                transportID: transportID,
                sessionID: entry["sessionId"] as? String
            )
        }

        let volume = status["volume"] as? [String: Any]

        return CastReceiverStatus(
            applications: applications,
            volumeLevel: (volume?["level"] as? NSNumber)?.doubleValue,
            volumeMuted: volume?["muted"] as? Bool
        )
    }

    /// Reads a media status object.
    private static func mediaStatus(from object: [String: Any]) -> CastMediaStatus {
        CastMediaStatus(
            mediaSessionID: (object["mediaSessionId"] as? NSNumber)?.intValue,
            playerState: object["playerState"] as? String,
            idleReason: object["idleReason"] as? String
        )
    }
}
