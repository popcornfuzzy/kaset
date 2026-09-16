import Foundation
import Testing
@testable import Kaset

/// ADTS headers that frame AAC access units for the Cast receiver.
@Suite(.tags(.service))
struct ADTSHeaderTests {
    // MARK: - Sampling Rate Mapping

    @Test("Maps sample rates to their ADTS indices")
    func mapsSampleRatesToIndices() {
        #expect(ADTSHeader.samplingFrequencyIndex(forSampleRate: 96000) == .hz96000)
        #expect(ADTSHeader.samplingFrequencyIndex(forSampleRate: 48000) == .hz48000)
        #expect(ADTSHeader.samplingFrequencyIndex(forSampleRate: 44100) == .hz44100)
        #expect(ADTSHeader.samplingFrequencyIndex(forSampleRate: 22050) == .hz22050)
        #expect(ADTSHeader.samplingFrequencyIndex(forSampleRate: 8000) == .hz8000)
    }

    @Test("Rejects sample rates ADTS cannot express")
    func rejectsUnsupportedSampleRates() {
        #expect(ADTSHeader.samplingFrequencyIndex(forSampleRate: 12345) == nil)
        #expect(ADTSHeader.header(payloadByteCount: 10, sampleRate: 100, channelCount: 2) == nil)
    }

    // MARK: - Header Bytes

    @Test("Builds the documented header for 44.1 kHz stereo")
    func buildsStereoHeaderAt44100() {
        // 100-byte access unit: frame length 107, stereo channel configuration 2, index 4.
        let header = ADTSHeader.header(payloadByteCount: 100, sampleRate: 44100, channelCount: 2)

        #expect(header == [0xFF, 0xF1, 0x50, 0x80, 0x0D, 0x7F, 0xFC])
    }

    @Test("Builds a mono header with channel configuration zero")
    func buildsMonoHeader() throws {
        let header = try #require(ADTSHeader.header(payloadByteCount: 100, sampleRate: 48000, channelCount: 1))

        // Profile AAC-LC (01) and sampling index 3 (48000 Hz) in the second byte; a mono stream
        // stores channel configuration 0.
        #expect(header[1] == 0xF1)
        #expect(header[2] == 0x4C)
        #expect(header[3] == 0x00)
    }

    @Test("Frame length counts the header and the payload")
    func frameLengthIncludesHeader() throws {
        let payloadByteCount = 500
        let header = try #require(ADTSHeader.header(payloadByteCount: payloadByteCount, sampleRate: 44100, channelCount: 2))

        let frameLength = (Int(header[3] & 0x03) << 11)
            | (Int(header[4]) << 3)
            | Int(header[5] >> 5)

        #expect(frameLength == payloadByteCount + ADTSHeader.length)
    }

    @Test("Header is seven bytes long")
    func headerLengthIsSevenBytes() throws {
        let header = try #require(ADTSHeader.header(payloadByteCount: 1, sampleRate: 44100, channelCount: 2))
        #expect(header.count == ADTSHeader.length)
    }

    @Test("Sync word and protection bits are constant")
    func syncWordIsConstant() throws {
        let header = try #require(ADTSHeader.header(payloadByteCount: 1, sampleRate: 44100, channelCount: 2))

        #expect(header[0] == 0xFF)
        // MPEG-4, layer 00, protection absent.
        #expect(header[1] & 0xF0 == 0xF0)
        #expect(header[1] & 0x08 == 0x00)
        #expect(header[1] & 0x01 == 0x01)
    }

    @Test("Rejects payloads too large for the 13-bit length field")
    func rejectsOversizedPayload() {
        #expect(ADTSHeader.header(payloadByteCount: 9000, sampleRate: 44100, channelCount: 2) == nil)
    }

    @Test("Rejects channel counts the format cannot express")
    func rejectsTooManyChannels() {
        #expect(ADTSHeader.header(payloadByteCount: 10, sampleRate: 44100, channelCount: 8) == nil)
    }

    // MARK: - Framing

    @Test("Framing prefixes the access unit with its header")
    func framesAccessUnit() throws {
        let accessUnit = Data([0x01, 0x02, 0x03])
        let framed = ADTSHeader.frame(accessUnit: accessUnit, sampleRate: 44100, channelCount: 2)

        #expect(framed.count == accessUnit.count + ADTSHeader.length)
        #expect(Array(framed.prefix(ADTSHeader.length)) == ADTSHeader.header(
            payloadByteCount: accessUnit.count,
            sampleRate: 44100,
            channelCount: 2
        ))
        #expect(Array(framed.dropFirst(ADTSHeader.length)) == [0x01, 0x02, 0x03])
    }

    @Test("Framing leaves an unframeable access unit untouched")
    func framingPassesThroughUnframeableUnit() {
        let accessUnit = Data([0x01, 0x02, 0x03])
        let framed = ADTSHeader.frame(accessUnit: accessUnit, sampleRate: 100, channelCount: 2)

        #expect(framed == accessUnit)
    }
}
