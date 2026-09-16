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
///
/// ## Feeding a live converter
///
/// `AudioConverterFillComplexBuffer` pulls input through a callback, and the callback's contract is
/// what shapes this class. The converter asks for a *minimum* number of input packets — two AAC
/// frames' worth, in practice — and calls back again while it has less. Returning **zero** packets
/// means *end of stream*: the converter flushes and never encodes again, which is how a live stream
/// turns into a silent one.
///
/// A capture tap delivers far less than that per callback (tens of milliseconds), so the encoder
/// queues input and only starts a conversion once a whole conversion's worth is available. That keeps
/// every request satisfiable from real audio, and with it the stream's timeline: padding requests
/// with silence would insert gaps and stretch the track.
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
    private let framesPerPacket: Int
    private let maximumOutputPacketSize: Int
    private let conversionContext = ConversionContext()

    /// Frames of input a conversion needs before it is worth starting.
    ///
    /// The converter asks for about two packets per call, so waiting for two keeps its requests
    /// satisfiable from real audio. If a conversion ever has to pad a request instead, the requirement
    /// grows to the size it asked for, so an unusual configuration self-corrects rather than thinning
    /// the stream on every conversion.
    private var requiredFrameCount: Int

    /// Ceiling on ``requiredFrameCount``, so a demanding converter cannot buffer a noticeable delay
    /// into a live stream.
    private let maximumRequiredFrameCount: Int

    /// Frames of silence that had to be substituted for missing audio, for diagnostics and tests.
    ///
    /// A growing value means the encoder is not being fed enough audio to satisfy the converter, which
    /// would stretch playback instead of playing it.
    private(set) var paddedFrameCount = 0

    /// Queued capture, held in the shape of the converter's input buffers.
    private var queuedBuffers: [Data]
    private var queuedFrameCount = 0

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
        let bitRateStatus = AudioConverterSetProperty(
            converter,
            kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout<UInt32>.size),
            &bitRate
        )
        if bitRateStatus != noErr {
            DiagnosticsLogger.cast.warning(
                "The AAC encoder refused the \(configuration.bitRate) bit/s target (OSStatus \(bitRateStatus)); the stream will use the encoder's own rate."
            )
        }

        var maximumPacketSize: UInt32 = 0
        var maximumPacketSizeValue = UInt32(MemoryLayout<UInt32>.size)
        let sizeStatus = AudioConverterGetProperty(
            converter,
            kAudioConverterPropertyMaximumOutputPacketSize,
            &maximumPacketSizeValue,
            &maximumPacketSize
        )

        let framesPerPacket = max(Int(outputFormat.mFramesPerPacket), 1)

        self.converter = converter
        self.inputFormat = inputFormat
        self.layout = layout
        self.sampleRate = inputFormat.mSampleRate
        self.channelCount = layout.channelCount
        self.framesPerPacket = framesPerPacket
        self.requiredFrameCount = framesPerPacket * 2
        self.maximumRequiredFrameCount = framesPerPacket * 8
        self.maximumOutputPacketSize = sizeStatus == noErr && maximumPacketSize > 0
            ? Int(maximumPacketSize)
            : 2048
        self.queuedBuffers = Array(repeating: Data(), count: layout.bufferCount)
    }

    deinit {
        AudioConverterDispose(self.converter)
    }

    /// Queues one captured PCM buffer and returns the ADTS-framed AAC it completed, if any.
    ///
    /// Most calls return nothing: a capture buffer holds a fraction of an AAC frame, so audio comes
    /// out every few callbacks rather than on every one.
    func encode(_ buffer: AudioTapBuffer) throws -> Data {
        guard !buffer.payload.isEmpty else { return Data() }

        self.enqueue(buffer)

        guard self.queuedFrameCount >= self.requiredFrameCount else {
            return Data()
        }

        return try self.convertQueuedAudio()
    }

    // MARK: - Queueing

    /// Copies a captured buffer into the queue, keeping one entry per input buffer.
    private func enqueue(_ buffer: AudioTapBuffer) {
        guard buffer.bufferByteSizes.count == self.layout.bufferCount else { return }
        guard buffer.bufferByteSizes.reduce(0, +) <= buffer.payload.count else { return }

        var offset = 0
        for index in 0 ..< self.layout.bufferCount {
            let byteCount = buffer.bufferByteSizes[index]
            self.queuedBuffers[index].append(buffer.payload[offset ..< offset + byteCount])
            offset += byteCount
        }

        self.queuedFrameCount += buffer.frameCount
    }

    /// Discards the queued audio, called once it has been handed to a conversion.
    private func resetQueue() {
        for index in 0 ..< self.queuedBuffers.count {
            self.queuedBuffers[index].removeAll(keepingCapacity: true)
        }
        self.queuedFrameCount = 0
    }

    // MARK: - Conversion

    /// Converts the queued audio into ADTS-framed AAC.
    private func convertQueuedAudio() throws -> Data {
        let frameCount = self.queuedFrameCount
        let packetCapacity = frameCount / self.framesPerPacket
        guard packetCapacity > 0 else { return Data() }

        // The queue is laid out as one contiguous block per input buffer, in buffer order, which is
        // what the converter's buffer list points into.
        let bufferByteSizes = self.queuedBuffers.map(\.count)
        let byteCount = bufferByteSizes.reduce(0, +)
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: max(byteCount, 1),
            alignment: MemoryLayout<Float>.alignment
        )
        defer { storage.deallocate() }

        var offset = 0
        for (index, queued) in self.queuedBuffers.enumerated() {
            guard !queued.isEmpty else { continue }
            queued.copyBytes(
                to: storage.advanced(by: offset).assumingMemoryBound(to: UInt8.self),
                count: queued.count
            )
            offset += bufferByteSizes[index]
        }

        self.resetQueue()

        let outputCapacity = packetCapacity * self.maximumOutputPacketSize
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
            count: packetCapacity
        )

        self.conversionContext.prepare(
            storage: storage,
            bufferByteSizes: bufferByteSizes,
            frameCount: frameCount,
            channelsPerBuffer: self.layout.channelsPerBuffer
        )

        var outputPacketCount = UInt32(packetCapacity)
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

        // A request the converter could not satisfy from real audio was padded, so ask for more input
        // next time rather than letting every conversion stretch the stream.
        if self.conversionContext.paddedFrameCount > 0 {
            self.paddedFrameCount += self.conversionContext.paddedFrameCount
            self.requiredFrameCount = min(
                max(self.requiredFrameCount, self.conversionContext.maximumRequestedFrameCount),
                self.maximumRequiredFrameCount
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
/// `AudioConverterFillComplexBuffer` pulls input through a C function pointer, so the source audio for
/// the current call is parked here and reached through the callback's `userData` pointer. The callback
/// hands the converter one slice per request, because the converter consumes exactly what it asked
/// for and forgets the rest.
final class ConversionContext: @unchecked Sendable {
    private var storage: UnsafeMutableRawPointer?
    private var bufferByteSizes: [Int] = []
    private var bufferOffsets: [Int] = []
    private var bytesPerBufferFrame: [Int] = []
    private var channelsPerBuffer: UInt32 = 2
    private var totalFrameCount = 0
    private var providedFrameCount = 0

    /// Frames of silence handed over during the current conversion.
    private(set) var paddedFrameCount = 0

    /// Largest request the converter made during the current conversion.
    private(set) var maximumRequestedFrameCount = 0

    /// Scratch used to answer a request that outruns the prepared audio.
    private var silence: UnsafeMutableRawPointer?
    private var silenceCapacity = 0

    deinit {
        self.silence?.deallocate()
    }

    /// Parks the audio for the next conversion call.
    ///
    /// The pointers must stay valid until that call returns, which the encoder guarantees.
    func prepare(
        storage: UnsafeMutableRawPointer,
        bufferByteSizes: [Int],
        frameCount: Int,
        channelsPerBuffer: Int
    ) {
        self.storage = storage
        self.bufferByteSizes = bufferByteSizes
        self.channelsPerBuffer = UInt32(channelsPerBuffer)
        self.totalFrameCount = frameCount
        self.providedFrameCount = 0
        self.paddedFrameCount = 0
        self.maximumRequestedFrameCount = 0

        // Bytes one sample frame occupies in each buffer, and where each buffer starts. All buffers
        // carry the same number of frames, so the offsets follow from the byte sizes.
        self.bytesPerBufferFrame = bufferByteSizes.map { size in
            frameCount > 0 ? size / frameCount : 0
        }

        var offset = 0
        self.bufferOffsets = bufferByteSizes.map { size in
            defer { offset += size }
            return offset
        }
    }

    /// Answers the converter's request, advancing through the prepared audio.
    func provide(
        packetCountPointer: UnsafeMutablePointer<UInt32>,
        bufferListPointer: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        guard let storage = self.storage, !self.bufferByteSizes.isEmpty else {
            packetCountPointer.pointee = 0
            return noErr
        }

        let requested = Int(packetCountPointer.pointee)
        self.maximumRequestedFrameCount = max(self.maximumRequestedFrameCount, requested)
        let remaining = self.totalFrameCount - self.providedFrameCount
        let supplied = min(requested, remaining)

        // Padding keeps a request answerable when the converter asks for more than the queued audio
        // covers, which happens once per converter while it primes. Answering zero instead would end
        // the stream for good.
        let isPadding = supplied < requested
        let frames = isPadding ? requested : supplied
        let maximumBytesPerFrame = self.bytesPerBufferFrame.max() ?? 0

        let source = isPadding
            ? self.silenceBuffer(byteCount: self.bufferByteSizes.count * frames * maximumBytesPerFrame)
            : storage
        guard let source else {
            packetCountPointer.pointee = 0
            return noErr
        }

        let destination = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        destination.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(self.bufferByteSizes.count)

        for index in 0 ..< self.bufferByteSizes.count {
            let bytesPerFrame = isPadding ? maximumBytesPerFrame : self.bytesPerBufferFrame[index]
            destination[index].mNumberChannels = self.channelsPerBuffer
            destination[index].mDataByteSize = UInt32(frames * bytesPerFrame)
            destination[index].mData = isPadding
                ? source.advanced(by: index * frames * bytesPerFrame)
                : source.advanced(by: self.bufferOffsets[index] + self.providedFrameCount * bytesPerFrame)
        }

        packetCountPointer.pointee = UInt32(frames)
        if isPadding {
            self.paddedFrameCount += requested
        } else {
            self.providedFrameCount += supplied
        }

        return noErr
    }

    /// A zero-filled buffer of at least `byteCount` bytes, used to answer requests that outrun the
    /// prepared audio.
    private func silenceBuffer(byteCount: Int) -> UnsafeMutableRawPointer? {
        guard byteCount > 0 else { return nil }

        if let silence = self.silence, self.silenceCapacity >= byteCount {
            return silence
        }

        self.silence?.deallocate()
        let capacity = byteCount * 2
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<Float>.alignment)
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
        self.silence = buffer
        self.silenceCapacity = capacity
        return buffer
    }
}

/// C input callback used by ``AACStreamEncoder``.
private let aacStreamEncoderInputProc: AudioConverterComplexInputDataProc = { _, packetCountPointer, bufferListPointer, _, userData in
    guard let userData else {
        packetCountPointer.pointee = 0
        return noErr
    }

    let context = Unmanaged<ConversionContext>.fromOpaque(userData).takeUnretainedValue()
    return context.provide(packetCountPointer: packetCountPointer, bufferListPointer: bufferListPointer)
}
