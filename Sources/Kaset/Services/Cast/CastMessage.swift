import Foundation

// MARK: - CastPayload

/// The payload of a CASTV2 message.
///
/// Cast senders and receivers exchange JSON documents in ``string(_:)`` payloads.
/// Binary payloads are used by the device-authentication channel, which Kaset does not use.
enum CastPayload: Equatable, Sendable {
    /// A UTF-8 payload. Cast JSON control messages use this case.
    case string(String)

    /// A raw binary payload.
    case binary(Data)

    /// The payload as UTF-8 text, when the payload is a string payload.
    var payloadUtf8: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }
}

// MARK: - CastMessage

/// A CASTV2 protocol message.
///
/// The Cast protocol frames a hand-rolled protobuf message over TLS. The message shape is small
/// and stable, so Kaset encodes and decodes the wire format directly instead of taking a
/// protobuf dependency.
///
/// ```text
/// message CastMessage {
///   optional ProtocolVersion protocol_version = 1;   // 0 == CASTV2_1_0
///   required string source_id                = 2;
///   required string destination_id           = 3;
///   required string namespace                = 4;
///   optional PayloadType payload_type        = 5;   // 0 == STRING, 1 == BINARY
///   optional string payload_utf8             = 6;
///   optional bytes  payload_binary           = 7;
/// }
/// ```
struct CastMessage: Equatable, Sendable {
    /// The protocol version field value sent by every Cast sender (`CASTV2_1_0`).
    static let protocolVersion: UInt64 = 0

    /// Stable identifier of the endpoint sending the message, e.g. `sender-0`.
    var sourceId: String

    /// Stable identifier of the endpoint receiving the message, e.g. `receiver-0`.
    var destinationId: String

    /// The Cast namespace the message belongs to.
    var namespace: String

    /// The message payload.
    var payload: CastPayload

    /// Creates a message carrying a JSON payload.
    init(
        sourceId: String,
        destinationId: String,
        namespace: String,
        payload: CastPayload = .string("")
    ) {
        self.sourceId = sourceId
        self.destinationId = destinationId
        self.namespace = namespace
        self.payload = payload
    }

    /// Creates a message carrying an empty JSON payload.
    init(sourceId: String, destinationId: String, namespace: String) {
        self.init(sourceId: sourceId, destinationId: destinationId, namespace: namespace, payload: .string(""))
    }
}

// MARK: - Errors

/// Errors thrown while encoding or decoding CASTV2 wire data.
enum CastMessageError: Error, Equatable {
    /// The buffer ended in the middle of a field.
    case truncated

    /// A field used a wire type the codec does not understand.
    case unsupportedWireType(UInt64)

    /// A varint used more bytes than the format permits.
    case malformedVarint

    /// A message did not carry the fields every CASTV2 message requires.
    case missingRequiredField(String)

    /// The stream framing announced a message larger than the safety limit.
    case oversizedMessage(Int)
}

// MARK: - Wire Format

/// Protobuf wire types used by the CASTV2 control protocol.
private enum CastWireType: UInt64 {
    case varint = 0
    case lengthDelimited = 2
}

/// Field numbers of the `CastMessage` protobuf message.
private enum CastMessageField: UInt64 {
    case protocolVersion = 1
    case sourceId = 2
    case destinationId = 3
    case namespace = 4
    case payloadType = 5
    case payloadUtf8 = 6
    case payloadBinary = 7

    /// The protobuf tag byte(s) for a field using the given wire type.
    func tag(_ wireType: CastWireType) -> [UInt8] {
        CastWireFormat.varint((self.rawValue << 3) | wireType.rawValue)
    }
}

/// Minimal protobuf primitives shared by the CASTV2 codec.
enum CastWireFormat {
    /// Encodes a base-128 varint.
    static func varint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 {
                byte |= 0x80
            }
            bytes.append(byte)
        } while remaining != 0
        return bytes
    }

    /// Reads a base-128 varint starting at `index`, returning the value and the next offset.
    static func readVarint(from bytes: [UInt8], index: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        while index < bytes.count {
            let byte = bytes[index]
            index += 1

            guard shift < 64 else {
                throw CastMessageError.malformedVarint
            }

            result |= UInt64(byte & 0x7F) << shift

            if byte & 0x80 == 0 {
                return result
            }

            shift += 7
        }

        throw CastMessageError.truncated
    }

    /// Encodes a length-delimited field body: the length prefix followed by the payload bytes.
    static func lengthDelimited(_ payload: [UInt8]) -> [UInt8] {
        var bytes = self.varint(UInt64(payload.count))
        bytes.append(contentsOf: payload)
        return bytes
    }

    /// Reads a length-delimited field body starting at `index`.
    static func readLengthDelimited(from bytes: [UInt8], index: inout Int) throws -> [UInt8] {
        let length = try readVarint(from: bytes, index: &index)
        guard length <= UInt64(Int.max) else {
            throw CastMessageError.truncated
        }
        let count = Int(length)

        guard count >= 0, index + count <= bytes.count else {
            throw CastMessageError.truncated
        }

        let value = Array(bytes[index ..< index + count])
        index += count
        return value
    }

    /// Reads and discards a field body of the given wire type.
    static func skip(from bytes: [UInt8], index: inout Int, wireType: UInt64) throws {
        switch CastWireType(rawValue: wireType) {
        case .varint:
            _ = try self.readVarint(from: bytes, index: &index)
        case .lengthDelimited:
            _ = try self.readLengthDelimited(from: bytes, index: &index)
        case nil:
            switch wireType {
            case 1:
                let count = 8
                guard index + count <= bytes.count else { throw CastMessageError.truncated }
                index += count
            case 5:
                let count = 4
                guard index + count <= bytes.count else { throw CastMessageError.truncated }
                index += count
            default:
                throw CastMessageError.unsupportedWireType(wireType)
            }
        }
    }
}

// MARK: - Encoding

extension CastMessage {
    /// The protobuf-encoded message body, without the 4-byte stream length prefix.
    func encoded() -> Data {
        var bytes: [UInt8] = []

        bytes.append(contentsOf: CastMessageField.protocolVersion.tag(.varint))
        bytes.append(contentsOf: CastWireFormat.varint(Self.protocolVersion))

        bytes.append(contentsOf: CastMessageField.sourceId.tag(.lengthDelimited))
        bytes.append(contentsOf: CastWireFormat.lengthDelimited(Array(self.sourceId.utf8)))

        bytes.append(contentsOf: CastMessageField.destinationId.tag(.lengthDelimited))
        bytes.append(contentsOf: CastWireFormat.lengthDelimited(Array(self.destinationId.utf8)))

        bytes.append(contentsOf: CastMessageField.namespace.tag(.lengthDelimited))
        bytes.append(contentsOf: CastWireFormat.lengthDelimited(Array(self.namespace.utf8)))

        switch self.payload {
        case let .string(value):
            bytes.append(contentsOf: CastMessageField.payloadType.tag(.varint))
            bytes.append(contentsOf: CastWireFormat.varint(0))
            if !value.isEmpty {
                bytes.append(contentsOf: CastMessageField.payloadUtf8.tag(.lengthDelimited))
                bytes.append(contentsOf: CastWireFormat.lengthDelimited(Array(value.utf8)))
            }

        case let .binary(data):
            bytes.append(contentsOf: CastMessageField.payloadType.tag(.varint))
            bytes.append(contentsOf: CastWireFormat.varint(1))
            bytes.append(contentsOf: CastMessageField.payloadBinary.tag(.lengthDelimited))
            bytes.append(contentsOf: CastWireFormat.lengthDelimited(Array(data)))
        }

        return Data(bytes)
    }

    /// The message body prefixed with the big-endian length header used on the Cast TLS stream.
    func framed() -> Data {
        let body = self.encoded()
        var frame = Data([
            UInt8((body.count >> 24) & 0xFF),
            UInt8((body.count >> 16) & 0xFF),
            UInt8((body.count >> 8) & 0xFF),
            UInt8(body.count & 0xFF),
        ])
        frame.append(body)
        return frame
    }

    /// Decodes a protobuf-encoded message body.
    static func decode(from data: Data) throws -> CastMessage {
        let bytes = [UInt8](data)
        var index = 0

        var sourceId: String?
        var destinationId: String?
        var namespace: String?
        var payloadType: UInt64 = 0
        var payloadUtf8: String?
        var payloadBinary: Data?

        while index < bytes.count {
            let tag = try CastWireFormat.readVarint(from: bytes, index: &index)
            let fieldNumber = tag >> 3
            let wireType = tag & 0x7

            guard let field = CastMessageField(rawValue: fieldNumber) else {
                try CastWireFormat.skip(from: bytes, index: &index, wireType: wireType)
                continue
            }

            switch field {
            case .protocolVersion:
                _ = try CastWireFormat.readVarint(from: bytes, index: &index)

            case .sourceId, .destinationId, .namespace, .payloadUtf8, .payloadBinary:
                guard wireType == CastWireType.lengthDelimited.rawValue else {
                    try CastWireFormat.skip(from: bytes, index: &index, wireType: wireType)
                    continue
                }
                let value = try CastWireFormat.readLengthDelimited(from: bytes, index: &index)
                switch field {
                case .sourceId:
                    sourceId = String(decoding: value, as: UTF8.self)
                case .destinationId:
                    destinationId = String(decoding: value, as: UTF8.self)
                case .namespace:
                    namespace = String(decoding: value, as: UTF8.self)
                case .payloadUtf8:
                    payloadUtf8 = String(decoding: value, as: UTF8.self)
                case .payloadBinary:
                    payloadBinary = Data(value)
                default:
                    break
                }

            case .payloadType:
                guard wireType == CastWireType.varint.rawValue else {
                    try CastWireFormat.skip(from: bytes, index: &index, wireType: wireType)
                    continue
                }
                payloadType = try CastWireFormat.readVarint(from: bytes, index: &index)
            }
        }

        guard let sourceId else { throw CastMessageError.missingRequiredField("sourceId") }
        guard let destinationId else { throw CastMessageError.missingRequiredField("destinationId") }
        guard let namespace else { throw CastMessageError.missingRequiredField("namespace") }

        let payload: CastPayload = if payloadType == 1, let payloadBinary {
            .binary(payloadBinary)
        } else {
            .string(payloadUtf8 ?? "")
        }

        return CastMessage(
            sourceId: sourceId,
            destinationId: destinationId,
            namespace: namespace,
            payload: payload
        )
    }
}

// MARK: - CastMessageFramer

/// Reassembles ``CastMessage`` values from the byte stream delivered by a TLS connection.
///
/// Cast frames each message with a 4-byte big-endian length. A single read from the socket may
/// contain several messages, or half of one, so callers append whatever arrives and pull complete
/// messages out.
struct CastMessageFramer {
    /// Messages larger than this are treated as protocol violations.
    static let maximumMessageSize = 1 << 20

    /// Received bytes not yet consumed.
    ///
    /// Bytes are read through an explicit offset rather than dropped from the front: `Data` keeps a
    /// non-zero `startIndex` after `removeFirst`, which would make index-based reads ambiguous.
    private var buffer: [UInt8] = []
    private var readOffset = 0

    /// Number of bytes waiting for the rest of their message.
    var bufferedByteCount: Int {
        self.buffer.count - self.readOffset
    }

    /// Appends freshly received bytes.
    mutating func append(_ data: Data) {
        self.compactIfNeeded()
        self.buffer.append(contentsOf: data)
    }

    /// Removes and returns the next complete message, or `nil` when more bytes are needed.
    mutating func nextMessage() throws -> CastMessage? {
        guard self.bufferedByteCount >= 4 else { return nil }

        let start = self.readOffset
        let length = Int(self.buffer[start]) << 24
            | Int(self.buffer[start + 1]) << 16
            | Int(self.buffer[start + 2]) << 8
            | Int(self.buffer[start + 3])

        guard length <= Self.maximumMessageSize else {
            throw CastMessageError.oversizedMessage(length)
        }

        guard self.bufferedByteCount >= 4 + length else { return nil }

        let body = Data(self.buffer[(start + 4) ..< (start + 4 + length)])
        self.readOffset = start + 4 + length

        if self.readOffset == self.buffer.count {
            self.buffer.removeAll(keepingCapacity: true)
            self.readOffset = 0
        }

        return try CastMessage.decode(from: body)
    }

    /// Drops all buffered bytes, e.g. after a reconnect.
    mutating func reset() {
        self.buffer.removeAll(keepingCapacity: false)
        self.readOffset = 0
    }

    /// Reclaims consumed bytes once they take up a meaningful share of the buffer.
    private mutating func compactIfNeeded() {
        guard self.readOffset > 0, self.readOffset >= self.buffer.count / 2 else { return }
        self.buffer.removeFirst(self.readOffset)
        self.readOffset = 0
    }
}
