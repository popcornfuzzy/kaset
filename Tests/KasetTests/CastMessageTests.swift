import Foundation
import Testing
@testable import Kaset

/// CASTV2 wire-format encoding, decoding, and stream framing.
@Suite(.tags(.service))
struct CastMessageTests {
    // MARK: - Encoding

    @Test("Encodes the CASTV2 protobuf field layout exactly")
    func encodesExactFieldLayout() {
        let message = CastMessage(
            sourceId: "a",
            destinationId: "b",
            namespace: "c",
            payload: .string("d")
        )

        let expected: [UInt8] = [
            0x08, 0x00, // protocol_version = 0 (CASTV2_1_0)
            0x12, 0x01, 0x61, // source_id = "a"
            0x1A, 0x01, 0x62, // destination_id = "b"
            0x22, 0x01, 0x63, // namespace = "c"
            0x28, 0x00, // payload_type = 0 (STRING)
            0x32, 0x01, 0x64, // payload_utf8 = "d"
        ]

        #expect([UInt8](message.encoded()) == expected)
    }

    @Test("Encoding a message with no payload omits the payload field")
    func encodesEmptyPayloadWithoutPayloadField() {
        let message = CastMessage(sourceId: "sender-0", destinationId: "receiver-0", namespace: "ns")
        let bytes = [UInt8](message.encoded())

        // No field-6 tag should be present.
        #expect(!bytes.contains(0x32))
        #expect(bytes.contains(0x28))
    }

    @Test("Encoding a binary payload uses the binary field and payload type 1")
    func encodesBinaryPayload() {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let message = CastMessage(
            sourceId: "sender-0",
            destinationId: "receiver-0",
            namespace: "ns",
            payload: .binary(payload)
        )

        let bytes = [UInt8](message.encoded())
        #expect(bytes.contains(0x3A)) // field 7, length-delimited
        #expect(bytes.contains(0x28)) // payload_type tag
        #expect(bytes.contains(0x01)) // payload_type = BINARY

        let decoded = try? CastMessage.decode(from: message.encoded())
        #expect(decoded?.payload == .binary(payload))
    }

    // MARK: - Decoding

    @Test("Round trips every field")
    func roundTripsFields() throws {
        let message = CastMessage(
            sourceId: "sender-0",
            destinationId: "receiver-0",
            namespace: CastNamespace.media,
            payload: .string("{\"type\":\"PING\"}")
        )

        let decoded = try CastMessage.decode(from: message.encoded())
        #expect(decoded == message)
    }

    @Test("Decoding ignores unknown fields")
    func decodingSkipsUnknownFields() throws {
        var bytes: [UInt8] = [
            0x12, 0x01, 0x61,
            0x1A, 0x01, 0x62,
            0x22, 0x01, 0x63,
        ]
        // Field 9, varint wire type, which the codec does not know.
        bytes.append(contentsOf: [0x48, 0x7F])
        // Field 10, length-delimited wire type, also unknown.
        bytes.append(contentsOf: [0x52, 0x02, 0xAA, 0xBB])

        let decoded = try CastMessage.decode(from: Data(bytes))
        #expect(decoded.sourceId == "a")
        #expect(decoded.destinationId == "b")
        #expect(decoded.namespace == "c")
    }

    @Test("Decoding tolerates fields in any order")
    func decodingHandlesReorderedFields() throws {
        let bytes: [UInt8] = [
            0x32, 0x01, 0x64, // payload first
            0x22, 0x01, 0x63, // namespace
            0x12, 0x01, 0x61, // source
            0x1A, 0x01, 0x62, // destination
        ]

        let decoded = try CastMessage.decode(from: Data(bytes))
        #expect(decoded.payload.payloadUtf8 == "d")
        #expect(decoded.namespace == "c")
    }

    @Test("Decoding a truncated field throws")
    func decodingTruncatedFieldThrows() {
        // Field 2 announces five bytes but only two follow.
        let bytes: [UInt8] = [0x12, 0x05, 0x61, 0x62]

        #expect(throws: CastMessageError.self) {
            try CastMessage.decode(from: Data(bytes))
        }
    }

    @Test("Decoding a message without required fields throws")
    func decodingMissingRequiredFieldsThrows() {
        #expect(throws: CastMessageError.self) {
            try CastMessage.decode(from: Data())
        }
    }

    @Test("Decoding multi-byte varints handles large tags")
    func decodingHandlesLargeVarints() throws {
        // Protocol version encoded as a two-byte varint (300).
        let bytes: [UInt8] = [
            0x08, 0xAC, 0x02,
            0x12, 0x01, 0x61,
            0x1A, 0x01, 0x62,
            0x22, 0x01, 0x63,
        ]

        let decoded = try CastMessage.decode(from: Data(bytes))
        #expect(decoded.sourceId == "a")
    }

    // MARK: - Framing

    @Test("Framing prefixes the message with a big-endian length")
    func framingPrefixesLength() {
        let message = CastMessage(sourceId: "a", destinationId: "b", namespace: "c", payload: .string("d"))
        let frame = message.framed()
        let body = message.encoded()

        #expect(frame.count == body.count + 4)
        #expect([UInt8](frame.prefix(4)) == [0x00, 0x00, 0x00, UInt8(body.count)])
        #expect([UInt8](frame.dropFirst(4)) == [UInt8](body))
    }

    @Test("Framer returns nothing until a full message arrives")
    func framerWaitsForCompleteMessage() throws {
        var framer = CastMessageFramer()
        let frame = CastMessage(sourceId: "a", destinationId: "b", namespace: "c", payload: .string("d")).framed()

        framer.append(frame.prefix(3))
        let partial = try framer.nextMessage()
        #expect(partial == nil)

        framer.append(frame.dropFirst(3))
        let message = try framer.nextMessage()
        #expect(message?.sourceId == "a")

        let remaining = try framer.nextMessage()
        #expect(remaining == nil)
    }

    @Test("Framer drains several messages from one read")
    func framerDrainsMultipleMessages() throws {
        var framer = CastMessageFramer()

        let first = CastMessage(sourceId: "a", destinationId: "b", namespace: "c", payload: .string("1"))
        let second = CastMessage(sourceId: "d", destinationId: "e", namespace: "f", payload: .string("2"))
        framer.append(first.framed())
        framer.append(second.framed())

        let firstDecoded = try framer.nextMessage()
        let secondDecoded = try framer.nextMessage()
        let noneLeft = try framer.nextMessage()

        #expect(firstDecoded?.payload.payloadUtf8 == "1")
        #expect(secondDecoded?.payload.payloadUtf8 == "2")
        #expect(noneLeft == nil)
    }

    @Test("Framer rejects an oversized announced length")
    func framerRejectsOversizedMessage() {
        var framer = CastMessageFramer()
        // Announce a message far larger than the safety limit.
        framer.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))

        #expect(throws: CastMessageError.self) {
            try framer.nextMessage()
        }
    }

    @Test("Framer resets buffered bytes")
    func framerResets() {
        var framer = CastMessageFramer()
        framer.append(Data([0x00, 0x00]))
        #expect(framer.bufferedByteCount == 2)

        framer.reset()
        #expect(framer.bufferedByteCount == 0)
    }
}
