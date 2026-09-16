import AudioToolbox
import Foundation
import Testing
@testable import Kaset

/// AAC encoding for the Cast stream.
///
/// The receiver decodes what these tests produce, so besides "audio came out" they check the byte
/// structure: every frame must carry a 7-byte ADTS header whose length field agrees with the payload
/// that follows, and the frames must tile the buffer exactly with no trailing bytes.
@Suite(.tags(.service))
struct AACStreamEncoderTests {
    // MARK: - Encoding

    @Test("Encodes a tone into ADTS-framed AAC")
    func encodesTone() throws {
        let encoder = try AACStreamEncoder(anyFormat: interleaved48kStereo)

        let encoded = try self.encode(encoder: encoder, frames: 48_000)

        let parsed = try #require(ADTSStream.parse(encoded))
        #expect(!parsed.frames.isEmpty)
        #expect(parsed.frames.allSatisfy { !$0.payload.isEmpty })
    }

    @Test("Frames tile the stream exactly")
    func framesTileTheStream() throws {
        let encoder = try AACStreamEncoder(anyFormat: interleaved48kStereo)

        let encoded = try self.encode(encoder: encoder, frames: 24_000)

        let parsed = try #require(ADTSStream.parse(encoded))
        // No leftover bytes means every frame length agreed with the payload that followed it, which
        // is what a decoder relies on to find the next sync word.
        #expect(parsed.consumedByteCount == encoded.count)
    }

    @Test("Every frame describes 48 kHz stereo AAC-LC")
    func everyFrameDescribesTheEncodedFormat() throws {
        let encoder = try AACStreamEncoder(anyFormat: interleaved48kStereo)

        let encoded = try self.encode(encoder: encoder, frames: 24_000)

        let parsed = try #require(ADTSStream.parse(encoded))
        for frame in parsed.frames {
            // Sync word, MPEG-4, layer 0, no CRC.
            #expect(frame.header[0] == 0xFF)
            #expect(frame.header[1] == 0xF1)
            // AAC-LC profile, sampling frequency index 3 (48 kHz).
            #expect(frame.header[2] == 0x4C)
            // Stereo channel configuration in the top two bits.
            #expect(frame.header[3] & 0xC0 == 0x80)
        }
    }

    @Test("Encodes to a higher bit rate when configured with one")
    func honoursTheConfiguredBitRate() throws {
        // Noise is used because its bit rate follows the setting: a pure tone is cheap enough to
        // encode that it undershoots any target, which would hide a setting that never arrives.
        let lowRate = try self.encode(encoder: AACStreamEncoder(
            anyFormat: interleaved48kStereo,
            configuration: AACStreamEncoder.Configuration(bitRate: 96_000)
        ), frames: 48_000, amplitude: 0.5, usesNoise: true)

        let highRate = try self.encode(encoder: AACStreamEncoder(
            anyFormat: interleaved48kStereo,
            configuration: AACStreamEncoder.Configuration(bitRate: 256_000)
        ), frames: 48_000, amplitude: 0.5, usesNoise: true)

        #expect(highRate.count > lowRate.count * 3 / 2, "96 kbps gave \(lowRate.count), 256 kbps gave \(highRate.count)")
    }

    @Test("Fills the stream with captured audio rather than silence")
    func doesNotSubstituteSilence() throws {
        let encoder = try AACStreamEncoder(anyFormat: interleaved48kStereo)

        let encoded = try self.encode(encoder: encoder, frames: 48_000)

        // Padding a request with silence keeps the converter alive but stretches the track, so the
        // silence it substitutes is metered.
        #expect(encoder.paddedFrameCount == 0, "padded \(encoder.paddedFrameCount) frames")
        let parsed = try #require(ADTSStream.parse(encoded))
        #expect(parsed.frames.count == 46)
    }

    @Test("Encodes one frame per 1024 samples")
    func producesOneFramePer1024Samples() throws {
        let encoder = try AACStreamEncoder(anyFormat: interleaved48kStereo)

        let encoded = try self.encode(encoder: encoder, frames: 96_000)

        let parsed = try #require(ADTSStream.parse(encoded))
        // 96000 samples is 93.75 AAC frames of 1024 samples, and the encoder only converts what it can
        // fill, so the last partial frame stays queued.
        #expect(parsed.frames.count == 92, "produced \(parsed.frames.count) frames")
    }

    @Test("Queues the fraction of a frame that capture delivers")
    func queuesPartialFrames() throws {
        let encoder = try AACStreamEncoder(anyFormat: interleaved48kStereo)

        // One capture buffer is a fraction of an AAC frame, so the first few callbacks produce nothing.
        let first = try encoder.encode(self.interleavedBuffer(frameCount: 512, amplitude: 0.5))
        let second = try encoder.encode(self.interleavedBuffer(frameCount: 512, startFrame: 512, amplitude: 0.5))
        let third = try encoder.encode(self.interleavedBuffer(frameCount: 512, startFrame: 1024, amplitude: 0.5))
        let fourth = try encoder.encode(self.interleavedBuffer(frameCount: 512, startFrame: 1536, amplitude: 0.5))

        #expect(first.isEmpty)
        #expect(second.isEmpty)
        #expect(third.isEmpty)
        #expect(!fourth.isEmpty)
    }

    @Test("Encodes louder audio into more bytes than silence")
    func louderAudioEncodesIntoMoreBytes() throws {
        let encoder = try AACStreamEncoder(anyFormat: interleaved48kStereo)

        let tone = try self.encode(encoder: encoder, frames: 48_000, amplitude: 0.6)
        let silence = try self.encode(encoder: encoder, frames: 48_000, amplitude: 0)

        // Proves the converter is fed the captured samples rather than empty buffers or a dead stream.
        #expect(tone.count > silence.count)
    }

    @Test("Encodes non-interleaved capture buffers")
    func encodesPlanarBuffers() throws {
        // A process tap can deliver one buffer per channel, which takes a different code path when the
        // buffer list is rebuilt for the converter.
        let encoder = try AACStreamEncoder(anyFormat: planar48kStereo)

        var encoded = Data()
        for _ in 0 ..< 40 {
            encoded.append(try encoder.encode(self.planarBuffer(frames: 1024)))
        }

        let parsed = try #require(ADTSStream.parse(encoded))
        #expect(!parsed.frames.isEmpty)
    }

    @Test("Ignores an empty buffer")
    func ignoresEmptyBuffer() throws {
        let encoder = try AACStreamEncoder(anyFormat: interleaved48kStereo)

        let encoded = try encoder.encode(AudioTapBuffer(payload: Data(), bufferByteSizes: [0], frameCount: 0))

        #expect(encoded.isEmpty)
    }

    // MARK: - Unsupported Formats

    @Test("Rejects a sample rate ADTS cannot describe")
    func rejectsUnsupportedSampleRate() {
        var format = self.interleaved48kStereo
        format.mSampleRate = 12_345

        #expect(throws: AACStreamEncoderError.self) {
            _ = try AACStreamEncoder(anyFormat: format)
        }
    }

    @Test("Rejects more than two channels")
    func rejectsSurroundAudio() {
        var format = self.interleaved48kStereo
        format.mChannelsPerFrame = 6
        format.mBytesPerFrame = format.mBytesPerFrame * 6 / 2

        #expect(throws: AACStreamEncoderError.self) {
            _ = try AACStreamEncoder(anyFormat: format)
        }
    }

    // MARK: - Fixtures

    /// 48 kHz stereo Float32 packed into one buffer, as the tap reports on most Macs.
    private var interleaved48kStereo: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    /// The same audio delivered as one buffer per channel.
    private var planar48kStereo: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    /// Encodes `frames` sample frames one tap buffer at a time.
    ///
    /// Buffers are deliberately not a whole number of AAC frames, matching what the tap delivers.
    private func encode(
        encoder: AACStreamEncoder,
        frames: Int,
        amplitude: Float = 0.5,
        usesNoise: Bool = false
    ) throws -> Data {
        var encoded = Data()
        var remaining = frames
        var sampleOffset = 0

        while remaining > 0 {
            let frameCount = min(512, remaining)
            let buffer = self.interleavedBuffer(
                frameCount: frameCount,
                startFrame: sampleOffset,
                amplitude: amplitude,
                usesNoise: usesNoise
            )
            encoded.append(try encoder.encode(buffer))
            remaining -= frameCount
            sampleOffset += frameCount
        }

        return encoded
    }

    /// Builds an interleaved tap buffer holding a 440 Hz tone, noise, or silence at amplitude zero.
    private func interleavedBuffer(
        frameCount: Int,
        startFrame: Int = 0,
        amplitude: Float,
        usesNoise: Bool = false
    ) -> AudioTapBuffer {
        var samples = [Float](repeating: 0, count: frameCount * 2)
        var seed: UInt64 = 0x1234_5678_9ABC_DEF0
        for frame in 0 ..< frameCount {
            let value: Float
            if usesNoise {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let unit = Float((seed >> 40) & 0xFFFF) / Float(0xFFFF)
                value = amplitude * (unit * 2 - 1)
            } else {
                value = amplitude * Float(sin(2 * Double.pi * 440 * Double(startFrame + frame) / 48_000))
            }
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }

        let payload = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        return AudioTapBuffer(
            payload: payload,
            bufferByteSizes: [payload.count],
            frameCount: frameCount
        )
    }

    /// Builds a planar tap buffer: one buffer for the left channel, then the right.
    private func planarBuffer(frames: Int) -> AudioTapBuffer {
        var channel = [Float](repeating: 0, count: frames)
        for frame in 0 ..< frames {
            channel[frame] = 0.4 * Float(sin(2 * Double.pi * 440 * Double(frame) / 48_000))
        }

        let channelData = channel.withUnsafeBufferPointer { Data(buffer: $0) }
        return AudioTapBuffer(
            payload: channelData + channelData,
            bufferByteSizes: [channelData.count, channelData.count],
            frameCount: frames
        )
    }
}

// MARK: - ADTSStream

/// A parsed ADTS stream, used to check the structure the encoder emits.
private enum ADTSStream {
    /// One framed AAC access unit.
    struct Frame {
        /// The seven ADTS header bytes.
        let header: [UInt8]

        /// The AAC access unit that follows the header.
        let payload: Data
    }

    /// Frames plus how many bytes of the input they accounted for.
    struct Parsed {
        /// Frames in stream order.
        let frames: [Frame]

        /// Bytes consumed while parsing, which equals the input size when the stream is well formed.
        let consumedByteCount: Int
    }

    /// Walks an ADTS stream, stopping at the first frame that does not parse.
    static func parse(_ data: Data) -> Parsed? {
        let bytes = [UInt8](data)
        var frames: [Frame] = []
        var offset = 0

        while offset + ADTSHeader.length <= bytes.count {
            // Sync word plus a fixed MPEG-4 layer.
            guard bytes[offset] == 0xFF, bytes[offset + 1] & 0xF0 == 0xF0 else { return nil }

            let frameLength = (Int(bytes[offset + 3] & 0x03) << 11)
                | (Int(bytes[offset + 4]) << 3)
                | Int(bytes[offset + 5] >> 5)

            guard frameLength >= ADTSHeader.length, offset + frameLength <= bytes.count else { return nil }

            frames.append(
                Frame(
                    header: Array(bytes[offset ..< offset + ADTSHeader.length]),
                    payload: Data(bytes[(offset + ADTSHeader.length) ..< (offset + frameLength)])
                )
            )
            offset += frameLength
        }

        return Parsed(frames: frames, consumedByteCount: offset)
    }
}
