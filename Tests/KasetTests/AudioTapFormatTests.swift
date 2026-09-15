import CoreAudioTypes
import Foundation
import Testing
@testable import Kaset

/// How a captured Core Audio stream maps onto an `AudioBufferList`.
@Suite(.tags(.service))
struct AudioTapFormatTests {
    // MARK: - Layout

    @Test("Interleaved stereo uses one buffer carrying both channels")
    func interleavedStereoLayout() {
        let layout = AudioTapFormatLayout(format: Self.interleavedStereo())

        #expect(layout.isInterleaved)
        #expect(layout.bufferCount == 1)
        #expect(layout.channelsPerBuffer == 2)
        #expect(layout.channelCount == 2)
        #expect(layout.bytesPerFrame == 8)
        #expect(layout.bytesPerSample == 4)
    }

    @Test("Non-interleaved stereo uses one buffer per channel")
    func nonInterleavedStereoLayout() {
        let layout = AudioTapFormatLayout(format: Self.nonInterleavedStereo())

        #expect(!layout.isInterleaved)
        #expect(layout.bufferCount == 2)
        #expect(layout.channelsPerBuffer == 1)
        #expect(layout.channelCount == 2)
        #expect(layout.bytesPerFrame == 4)
    }

    @Test("Non-interleaved mono uses a single buffer")
    func nonInterleavedMonoLayout() {
        let layout = AudioTapFormatLayout(format: Self.nonInterleavedMono())

        #expect(layout.bufferCount == 1)
        #expect(layout.channelsPerBuffer == 1)
        #expect(layout.channelCount == 1)
    }

    @Test("A stream with no channels reports one channel instead of none")
    func zeroChannelsIsTreatedAsMono() {
        let format = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 0,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        #expect(AudioTapFormatLayout(format: format).channelCount == 1)
    }

    // MARK: - Frame Accounting

    @Test("Derives the frame count from an interleaved buffer")
    func derivesFrameCountForInterleaved() {
        let layout = AudioTapFormatLayout(format: Self.interleavedStereo())

        #expect(layout.frameCount(forBufferByteSizes: [80]) == 10)
        #expect(layout.frameCount(forBufferByteSizes: []) == nil)
    }

    @Test("Rejects an interleaved buffer that is not a whole number of frames")
    func rejectsPartialInterleavedFrame() {
        let layout = AudioTapFormatLayout(format: Self.interleavedStereo())

        #expect(layout.frameCount(forBufferByteSizes: [7]) == nil)
    }

    @Test("Derives the frame count from non-interleaved buffers")
    func derivesFrameCountForNonInterleaved() {
        let layout = AudioTapFormatLayout(format: Self.nonInterleavedStereo())

        #expect(layout.frameCount(forBufferByteSizes: [40, 40]) == 10)
        #expect(layout.frameCount(forBufferByteSizes: [40]) == nil)
        #expect(layout.frameCount(forBufferByteSizes: [40, 40, 40]) == nil)
    }

    @Test("Rejects non-interleaved buffers of differing lengths")
    func rejectsMismatchedNonInterleavedBuffers() {
        let layout = AudioTapFormatLayout(format: Self.nonInterleavedStereo())

        #expect(layout.frameCount(forBufferByteSizes: [40, 36]) == nil)
    }

    @Test("Expected payload size scales with the frame count")
    func expectedPayloadSize() {
        let layout = AudioTapFormatLayout(format: Self.interleavedStereo())

        #expect(layout.payloadByteCount(frameCount: 0) == 0)
        #expect(layout.payloadByteCount(frameCount: 441) == 3528)
    }

    // MARK: - Captured Buffer

    @Test("Captured buffers carry payload, buffer sizes, and frame count")
    func capturedBufferShape() {
        let buffer = AudioTapBuffer(
            payload: Data(repeating: 0x00, count: 80),
            bufferByteSizes: [80],
            frameCount: 10
        )

        #expect(buffer.payload.count == 80)
        #expect(buffer.bufferByteSizes == [80])
        #expect(buffer.frameCount == 10)
    }

    // MARK: - Fixtures

    private static func interleavedStereo() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 44100,
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

    private static func nonInterleavedStereo() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private static func nonInterleavedMono() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}
