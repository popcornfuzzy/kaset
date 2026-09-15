import AudioToolbox
import CoreAudioTypes
import Foundation

/// MPEG-4 audio object type for AAC-LC.
///
/// `kMPEG4Object_AAC_LC` lives in an anonymous C enum that Swift does not import, so the value is
/// declared here and written into the AAC format flags.
private let aacLowComplexityObjectType: UInt32 = 2

// MARK: - AACStreamEncoderError

/// Errors raised while setting up or running the AAC encoder.
enum AACStreamEncoderError: LocalizedError {
    /// The stream format describes audio this encoder cannot accept.
    case unsupportedFormat(String)

    /// AudioToolbox refused to create the converter.
    case converterCreationFailed(OSStatus)

    /// AudioToolbox failed while converting a buffer.
    case conversionFailed(OSStatus)

    /// The converter produced no output buffer.
    case missingOutputBuffer

    var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(reason):
            "Unsupported audio format for casting: \(reason)"
        case let .converterCreationFailed(status):
            "Could not create the AAC encoder (OSStatus \(status))."
        case let .conversionFailed(status):
            "The AAC encoder failed (OSStatus \(status))."
        case .missingOutputBuffer:
            "The AAC encoder produced no output."
        }
    }
}

// MARK: - AACStreamEncoder

/// Encodes captured PCM audio to ADTS-framed AAC-LC for the Cast Default Media Receiver.
///
/// AAC access units are variable length, so every converted packet is framed with an ADTS header
/// before it is written to the stream.
final class AACStreamEncoder {
    /// Encoder configuration.
    struct Configuration: Sendable {
        /// Target bitrate in bits per second.
        var bitRate: Int = 192_000
    }

    /// Shape of the PCM the encoder accepts.
    let inputFormat: AudioStreamBasicDescription

    /// How the input format maps onto an `AudioBufferList`.
    let layout: AudioTapFormatLayout

    private let converter: AudioConverterRef
    private let sampleRate: Double
    private let channelCount: Int
    private let packetsPerFrame: UInt32
    private let maximumOutputPacketSize: Int
    private let conversionContext = ConversionContext()

    /// Creates an encoder fed by the given PCM format.
    ///
    /// - Parameters:
    ///   - anyFormat: Format of the PCM the device tap produces.
    ///   - configuration: Encoder settings.
    init(anyFormat inputFormat: AudioStreamBasicDescription, configuration: Configuration = Configuration()) throws {
        guard ADTSHeader.samplingFrequencyIndex(forSampleRate: inputFormat.mSampleRate) != nil else {
            throw AACStreamEncoderError.unsupportedFormat(
                "sample rate \(Int(inputFormat.mSampleRate)) Hz cannot be written to an ADTS stream"
            )
        }

        let layout = AudioTapFormatLayout(format: inputFormat)
        guard layout.channelCount >= 1, layout.channelCount <= 2 else {
            throw AACStreamEncoderError.unsupportedFormat("\(layout.channelCount) channels")
        }

        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: inputFormat.mSampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: aacLowComplexityObjectType,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(layout.channelCount),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        // `AudioConverterNew` takes both formats as in-out parameters.
        var sourceFormat = inputFormat
        var converter: AudioConverterRef?
        let status = AudioConverterNew(&sourceFormat, &outputFormat, &converter)
        guard status == noErr, let converter else {
            throw AACStreamEncoderError.converterCreationFailed(status)
        }

        var bitRate = UInt32(configuration.bitRate)
        AudioConverterSetProperty(
            converter,
            kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout<UInt32>.size),
            &bitRate
        )

        var maximumPacketSize: UInt32 = 0
        var maximumPacketSizeValue = UInt32(MemoryLayout<UInt32>.size)
        let sizeStatus = AudioConverterGetProperty(
            converter,
            kAudioConverterPropertyMaximumOutputPacketSize,
            &maximumPacketSizeValue,
            &maximumPacketSize
        )

        self.converter = converter
        self.inputFormat = inputFormat
        self.layout = layout
        self.sampleRate = inputFormat.mSampleRate
        self.channelCount = layout.channelCount
        self.packetsPerFrame = outputFormat.mFramesPerPacket
        self.maximumOutputPacketSize = sizeStatus == noErr && maximumPacketSize > 0
            ? Int(maximumPacketSize)
            : 2048
    }

    deinit {
        AudioConverterDispose(self.converter)
    }

    /// Encodes one captured PCM buffer and returns ADTS-framed AAC.
    func encode(_ buffer: AudioTapBuffer) throws -> Data {
        guard !buffer.payload.isEmpty else { return Data() }

        let inputByteCount = buffer.payload.count
        let inputStorage = UnsafeMutableRawPointer.allocate(
            byteCount: inputByteCount,
            alignment: MemoryLayout<Float>.alignment
        )
        defer { inputStorage.deallocate() }
        buffer.payload.copyBytes(to: inputStorage.assumingMemoryBound(to: UInt8.self), count: inputByteCount)

        guard let inputBufferList = self.makeInputBufferList(from: buffer, storage: inputStorage) else {
            throw AACStreamEncoderError.unsupportedFormat("buffer layout did not match the stream format")
        }
        defer { free(inputBufferList.unsafeMutablePointer) }

        let maximumPackets = max(Int(ceil(Double(buffer.frameCount) / Double(self.packetsPerFrame))) + 1, 2)
        let outputCapacity = maximumPackets * self.maximumOutputPacketSize

        let outputBufferList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(outputBufferList.unsafeMutablePointer) }
        outputBufferList[0].mNumberChannels = UInt32(self.channelCount)
        outputBufferList[0].mDataByteSize = UInt32(outputCapacity)
        let outputStorage = UnsafeMutableRawPointer.allocate(
            byteCount: outputCapacity,
            alignment: MemoryLayout<Float>.alignment
        )
        defer { outputStorage.deallocate() }
        outputBufferList[0].mData = outputStorage

        var packetDescriptions = [AudioStreamPacketDescription](
            repeating: AudioStreamPacketDescription(),
            count: maximumPackets
        )

        self.conversionContext.prepare(
            bufferList: inputBufferList,
            packetCount: UInt32(buffer.frameCount)
        )

        var outputPacketCount = UInt32(maximumPackets)
        let status = packetDescriptions.withUnsafeMutableBufferPointer { descriptions in
            AudioConverterFillComplexBuffer(
                self.converter,
                aacStreamEncoderInputProc,
                Unmanaged.passUnretained(self.conversionContext).toOpaque(),
                &outputPacketCount,
                outputBufferList.unsafeMutablePointer,
                descriptions.baseAddress
            )
        }

        // A conversion that produced no packets reports a non-zero status; a conversion that
        // produced audio succeeded even if the converter reports an informational result.
        guard status == noErr || outputPacketCount > 0 else {
            throw AACStreamEncoderError.conversionFailed(status)
        }

        guard outputPacketCount > 0, let outputData = outputBufferList[0].mData else {
            return Data()
        }

        return self.framePackets(
            outputData: outputData,
            packetCount: Int(outputPacketCount),
            packetDescriptions: packetDescriptions
        )
    }

    // MARK: - Helpers

    /// Rebuilds an `AudioBufferList` from the flattened tap buffer.
    ///
    /// The returned list points into `storage`, which the caller keeps alive for the duration of the
    /// conversion call.
    private func makeInputBufferList(
        from buffer: AudioTapBuffer,
        storage: UnsafeMutableRawPointer
    ) -> UnsafeMutableAudioBufferListPointer? {
        guard buffer.bufferByteSizes.count == self.layout.bufferCount else { return nil }
        guard buffer.payload.count >= buffer.bufferByteSizes.reduce(0, +) else { return nil }

        let bufferList = AudioBufferList.allocate(maximumBuffers: self.layout.bufferCount)
        bufferList.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(self.layout.bufferCount)

        var offset = 0
        for index in 0 ..< self.layout.bufferCount {
            let byteCount = buffer.bufferByteSizes[index]
            bufferList[index].mNumberChannels = UInt32(self.layout.channelsPerBuffer)
            bufferList[index].mDataByteSize = UInt32(byteCount)
            bufferList[index].mData = storage.advanced(by: offset)
            offset += byteCount
        }

        return bufferList
    }

    /// Walks the converter output, wrapping each packet in an ADTS header.
    private func framePackets(
        outputData: UnsafeMutableRawPointer,
        packetCount: Int,
        packetDescriptions: [AudioStreamPacketDescription]
    ) -> Data {
        var framed = Data()
        var offset = 0

        for index in 0 ..< packetCount {
            let byteCount = index < packetDescriptions.count
                ? Int(packetDescriptions[index].mDataByteSize)
                : 0
            guard byteCount > 0 else { continue }

            let accessUnit = Data(
                bytes: outputData.advanced(by: offset),
                count: byteCount
            )
            offset += byteCount

            framed.append(
                ADTSHeader.frame(
                    accessUnit: accessUnit,
                    sampleRate: self.sampleRate,
                    channelCount: self.channelCount
                )
            )
        }

        return framed
    }
}

// MARK: - ConversionContext

/// Hand-off between the encoder and the C input callback that feeds the converter.
///
/// `AudioConverterFillComplexBuffer` pulls input through a C function pointer, so the buffer for the
/// current call is parked here and reached through the callback's `userData` pointer.
final class ConversionContext: @unchecked Sendable {
    private var bufferList: UnsafeMutableAudioBufferListPointer?
    private var packetCount: UInt32 = 0
    private var hasProvidedBuffer = false

    /// Stores the input for the next conversion call.
    func prepare(bufferList: UnsafeMutableAudioBufferListPointer, packetCount: UInt32) {
        self.bufferList = bufferList
        self.packetCount = packetCount
        self.hasProvidedBuffer = false
    }

    /// Copies the parked input into the converter's request.
    ///
    /// Returns `0` when all input for this call has already been handed over, which tells the
    /// converter there is nothing more to read for now.
    func provide(
        packetCountPointer: UnsafeMutablePointer<UInt32>,
        bufferListPointer: UnsafeMutablePointer<AudioBufferList>
    ) -> UInt32 {
        guard !self.hasProvidedBuffer, let inputList = self.bufferList else {
            packetCountPointer.pointee = 0
            return 0
        }

        self.hasProvidedBuffer = true
        packetCountPointer.pointee = self.packetCount

        let destination = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        destination.unsafeMutablePointer.pointee.mNumberBuffers = inputList.unsafeMutablePointer.pointee.mNumberBuffers
        for index in 0 ..< inputList.count {
            destination[index] = inputList[index]
        }

        return self.packetCount
    }
}

/// C input callback used by ``AACStreamEncoder``.
private let aacStreamEncoderInputProc: AudioConverterComplexInputDataProc = { _, packetCountPointer, bufferListPointer, _, userData in
    guard let userData else {
        packetCountPointer.pointee = 0
        return noErr
    }

    let context = Unmanaged<ConversionContext>.fromOpaque(userData).takeUnretainedValue()
    _ = context.provide(packetCountPointer: packetCountPointer, bufferListPointer: bufferListPointer)
    return noErr
}
