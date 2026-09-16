import Foundation

// MARK: - ADTSHeader

/// Builds the 7-byte ADTS header that precedes each AAC frame on a live stream.
///
/// The Cast Default Media Receiver plays an AAC stream served as `audio/aac`, which requires each
/// AAC access unit to carry an ADTS header. The encoder produces raw access units, so Kaset frames
/// them here.
///
/// ```text
/// syncword (12) | ID (1) | layer (2) | protection_absent (1)
/// profile (2) | sampling_frequency_index (4) | private (1) | channel_configuration (3)
/// copyright bits (4) | aac_frame_length (13) | adts_buffer_fullness (11) | raw_blocks (2)
/// ```
enum ADTSHeader {
    /// Number of bytes in an ADTS header without the optional CRC.
    static let length = 7

    /// ADTS sampling frequency indices.
    enum SamplingFrequencyIndex: Int, Sendable {
        case hz96000 = 0
        case hz88200 = 1
        case hz64000 = 2
        case hz48000 = 3
        case hz44100 = 4
        case hz32000 = 5
        case hz24000 = 6
        case hz22050 = 7
        case hz16000 = 8
        case hz12000 = 9
        case hz11025 = 10
        case hz8000 = 11
    }

    /// Indicates a variable-rate stream, which live encoding always is.
    private static let bufferFullness = 0x7FF

    /// AAC-LC is MPEG-4 Audio Object Type 2; the ADTS profile field stores `objectType - 1`.
    private static let aacLowComplexityProfile: UInt8 = 1

    /// Maps a sample rate to its ADTS index.
    ///
    /// Returns `nil` for rates the format cannot express, which the Caller treats as unsupported.
    static func samplingFrequencyIndex(forSampleRate sampleRate: Double) -> SamplingFrequencyIndex? {
        switch Int(sampleRate.rounded()) {
        case 96000: .hz96000
        case 88200: .hz88200
        case 64000: .hz64000
        case 48000: .hz48000
        case 44100: .hz44100
        case 32000: .hz32000
        case 24000: .hz24000
        case 22050: .hz22050
        case 16000: .hz16000
        case 12000: .hz12000
        case 11025: .hz11025
        case 8000: .hz8000
        default: nil
        }
    }

    /// Builds the header for one AAC frame.
    ///
    /// - Parameters:
    ///   - payloadByteCount: Size of the AAC access unit that follows the header.
    ///   - sampleRate: Sample rate of the encoded audio.
    ///   - channelCount: Number of channels in the encoded audio.
    static func header(
        payloadByteCount: Int,
        sampleRate: Double,
        channelCount: Int
    ) -> [UInt8]? {
        guard payloadByteCount >= 0, let sampleRateIndex = self.samplingFrequencyIndex(forSampleRate: sampleRate) else {
            return nil
        }

        // ADTS encodes 0 for mono and the channel count for everything else. Encodes above 7
        // channels are not expressible and never occur here.
        let channelConfiguration = channelCount == 1 ? 0 : channelCount
        guard channelConfiguration <= 7 else { return nil }

        // The 13-bit field counts the header bytes as well as the payload.
        let frameLength = payloadByteCount + self.length
        guard frameLength <= 0x1FFF else { return nil }

        let channelConfigurationBits = UInt8(channelConfiguration)

        return [
            0xFF,
            0xF1,
            (self.aacLowComplexityProfile << 6)
                | (UInt8(sampleRateIndex.rawValue) << 2)
                | ((channelConfigurationBits >> 2) & 0x01),
            ((channelConfigurationBits & 0x03) << 6)
                | UInt8((frameLength >> 11) & 0x03),
            UInt8((frameLength >> 3) & 0xFF),
            UInt8((frameLength & 0x07) << 5) | UInt8((self.bufferFullness >> 6) & 0x1F),
            // Buffer fullness low bits, followed by zero raw data blocks in the frame.
            UInt8((self.bufferFullness & 0x3F) << 2),
        ]
    }

    /// Frames an AAC access unit with its ADTS header.
    ///
    /// Returns the raw access unit unchanged when it cannot be framed, so a bad frame degrades to a
    /// glitch instead of breaking the stream.
    static func frame(
        accessUnit: Data,
        sampleRate: Double,
        channelCount: Int
    ) -> Data {
        guard let header = self.header(
            payloadByteCount: accessUnit.count,
            sampleRate: sampleRate,
            channelCount: channelCount
        ) else {
            return accessUnit
        }

        var data = Data(header)
        data.append(accessUnit)
        return data
    }
}
