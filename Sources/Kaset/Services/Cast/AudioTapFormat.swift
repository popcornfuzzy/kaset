import AudioToolbox
import CoreAudioTypes
import Foundation

// MARK: - AudioTapBuffer

/// A block of captured PCM audio handed from the Core Audio tap to the encoder.
///
/// The tap delivers an ``AudioBufferList`` whose shape is fixed for the lifetime of the tap. Only
/// the byte sizes vary, so the buffer is flattened into ``payload`` with the per-buffer byte sizes
/// recorded alongside it.
struct AudioTapBuffer: Sendable, Equatable {
    /// Concatenated bytes of every buffer in the original buffer list.
    let payload: Data

    /// Byte size of each buffer in the original buffer list, in order.
    let bufferByteSizes: [Int]

    /// Number of sample frames in this buffer.
    let frameCount: Int
}

// MARK: - AudioTapFormatLayout

/// Describes how a Core Audio stream format maps onto an `AudioBufferList`.
///
/// Keeping this mapping in one value type lets the encoder rebuild a buffer list from the flattened
/// ``AudioTapBuffer`` payload without touching Core Audio state, and lets the mapping be unit tested
/// without an audio device.
struct AudioTapFormatLayout: Sendable, Equatable {
    /// Whether the samples for all channels are packed into a single buffer.
    let isInterleaved: Bool

    /// Number of buffers the stream uses: one when interleaved, one per channel otherwise.
    let bufferCount: Int

    /// Channels carried by each buffer.
    let channelsPerBuffer: Int

    /// Channels in the stream overall.
    let channelCount: Int

    /// Bytes in a single sample frame.
    let bytesPerFrame: Int

    /// Bytes used by one sample of one channel.
    let bytesPerSample: Int

    /// Derives the layout from a Core Audio stream description.
    init(format: AudioStreamBasicDescription) {
        let channels = max(Int(format.mChannelsPerFrame), 1)
        let isNonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        self.channelCount = channels
        self.isInterleaved = !isNonInterleaved
        self.bufferCount = isNonInterleaved ? channels : 1
        self.channelsPerBuffer = isNonInterleaved ? 1 : channels
        self.bytesPerSample = Int(format.mBitsPerChannel) / 8
        self.bytesPerFrame = max(Int(format.mBytesPerFrame), 1)
    }

    /// The total payload size expected for a buffer carrying `frameCount` frames.
    func payloadByteCount(frameCount: Int) -> Int {
        self.bytesPerFrame * frameCount
    }

    /// Derives the frame count from the per-buffer byte sizes of a captured buffer.
    ///
    /// Returns `nil` when the sizes cannot describe a whole number of frames.
    func frameCount(forBufferByteSizes sizes: [Int]) -> Int? {
        guard sizes.count == self.bufferCount else { return nil }

        if self.isInterleaved {
            guard let total = sizes.first else { return nil }
            guard total % self.bytesPerFrame == 0 else { return nil }
            return total / self.bytesPerFrame
        }

        // Non-interleaved: every buffer holds one channel of the same frames.
        let bytesPerChannelFrame = self.bytesPerSample
        var frames: Int?
        for size in sizes {
            guard bytesPerChannelFrame > 0, size % bytesPerChannelFrame == 0 else { return nil }
            let candidate = size / bytesPerChannelFrame
            if let frames, frames != candidate {
                return nil
            }
            frames = candidate
        }
        return frames
    }
}
