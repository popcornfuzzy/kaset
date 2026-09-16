import CoreAudio
import CoreAudioTypes
import Foundation

// MARK: - AudioProcessTapError

/// Errors raised while creating or running a Core Audio process tap.
enum AudioProcessTapError: LocalizedError {
    /// No process in the requested set could be tapped.
    case noProcessesAvailable

    /// Core Audio refused to create the tap.
    case tapCreationFailed

    /// Core Audio refused to create the private aggregate device that carries the tap.
    case aggregateDeviceCreationFailed

    /// Core Audio could not create the I/O callback.
    case ioProcCreationFailed(OSStatus)

    /// The aggregate device would not start.
    case deviceStartFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noProcessesAvailable:
            "No audio-producing process was found to cast."
        case .tapCreationFailed:
            "macOS refused to create the audio tap."
        case .aggregateDeviceCreationFailed:
            "macOS refused to create the audio capture device."
        case let .ioProcCreationFailed(status):
            "Could not attach to the audio capture device (OSStatus \(status))."
        case let .deviceStartFailed(status):
            "Could not start audio capture (OSStatus \(status))."
        }
    }
}

// MARK: - AudioProcessTap

/// Captures the audio a set of processes is playing.
///
/// Kaset casts by capturing the decoded audio it is already playing rather than by handing YouTube
/// URLs to the Cast device. That keeps DRM-protected playback working exactly as before, because
/// the audio is captured after WebKit has decoded it.
///
/// The tap is built from Core Audio's process-tap API: a tap object collects the audio, and a
/// private aggregate device carries it to an I/O callback that Kaset reads from. Tapping with
/// ``CATapMuteBehavior/mutedWhenTapped`` keeps the captured audio out of the local speakers, so
/// casting does not play the same track twice.
final class AudioProcessTap: @unchecked Sendable {
    /// Stream format produced by the tap.
    let format: AudioStreamBasicDescription

    /// How ``format`` maps onto captured buffers.
    let layout: AudioTapFormatLayout

    /// Processes that were actually tapped.
    ///
    /// Processes Core Audio does not know about cannot be tapped, so this can be a subset of the
    /// requested identifiers — a difference worth reporting, because the missing process is usually
    /// the one making the sound.
    let tappedProcessIDs: [pid_t]

    private let system: AudioHardwareSystem
    private let tap: AudioHardwareTap
    private let aggregateDevice: AudioHardwareAggregateDevice
    private var ioProcID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<AudioTapBuffer>.Continuation?
    private var isRunning = false

    /// Creates a tap over the given processes.
    ///
    /// - Parameters:
    ///   - processIDs: Processes whose audio should be captured.
    ///   - muteWhenTapped: Whether the captured audio should stop playing on the Mac's own output
    ///     while a client is reading the tap.
    init(processIDs: [pid_t], muteWhenTapped: Bool = true) throws {
        let system = AudioHardwareSystem.shared
        self.system = system

        var processObjects: [AudioObjectID] = []
        var tappedProcessIDs: [pid_t] = []
        for pid in processIDs {
            guard let process = try? system.process(for: pid) else { continue }
            processObjects.append(process.id)
            tappedProcessIDs.append(pid)
        }

        guard !processObjects.isEmpty else {
            throw AudioProcessTapError.noProcessesAvailable
        }

        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.name = "Kaset Cast"
        description.isPrivate = true
        if muteWhenTapped {
            description.muteBehavior = .mutedWhenTapped
        }

        guard let tap = try system.makeProcessTap(description: description) else {
            throw AudioProcessTapError.tapCreationFailed
        }

        let tapFormat = try tap.format

        guard let tapUID = try? tap.uid else {
            try? system.destroyProcessTap(tap)
            throw AudioProcessTapError.tapCreationFailed
        }

        // A private stacked aggregate device carries the tap to an I/O callback. The default output
        // device supplies the clock, which keeps the aggregate's timeline aligned with playback.
        var aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Kaset Cast",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]

        if let outputDevice = try? system.defaultOutputDevice, let outputDeviceUID = try? outputDevice.uid {
            aggregateDescription[kAudioAggregateDeviceMainSubDeviceKey] = outputDeviceUID
            aggregateDescription[kAudioAggregateDeviceSubDeviceListKey] = [
                [kAudioSubDeviceUIDKey: outputDeviceUID],
            ]
        }

        guard let aggregateDevice = try system.makeAggregateDevice(description: aggregateDescription) else {
            try? system.destroyProcessTap(tap)
            throw AudioProcessTapError.aggregateDeviceCreationFailed
        }

        // Align the capture stream with the tap's own format so no implicit conversion happens.
        if let streams = try? aggregateDevice.streams {
            for stream in streams where (try? stream.direction) == .input {
                try? stream.setVirtualFormat(tapFormat)
            }
        }

        self.tap = tap
        self.aggregateDevice = aggregateDevice
        self.format = tapFormat
        self.layout = AudioTapFormatLayout(format: tapFormat)
        self.tappedProcessIDs = tappedProcessIDs
    }

    /// Starts capturing and returns the audio stream.
    ///
    /// The stream ends when ``stop()`` is called. Buffered audio is bounded, so a slow consumer
    /// drops audio rather than delaying playback indefinitely.
    func start() -> AsyncStream<AudioTapBuffer> {
        let (stream, continuation) = AsyncStream<AudioTapBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        self.continuation = continuation

        let sink = TapSink(layout: self.layout, continuation: continuation)

        var ioProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            self.aggregateDevice.id,
            nil
        ) { _, inputData, _, _, _ in
            sink.consume(inputData)
        }

        guard status == noErr, let ioProcID else {
            continuation.finish()
            self.continuation = nil
            DiagnosticsLogger.cast.error("Failed to create audio I/O callback (OSStatus \(status))")
            return stream
        }

        self.ioProcID = ioProcID

        do {
            try self.aggregateDevice.start(IOProcID: ioProcID)
            self.isRunning = true
            let bufferLayout = self.layout.isInterleaved ? "interleaved" : "one buffer per channel"
            DiagnosticsLogger.cast.info(
                "Audio capture started at \(Int(self.format.mSampleRate)) Hz, \(self.layout.channelCount) channels, \(bufferLayout)"
            )
        } catch {
            DiagnosticsLogger.cast.error("Failed to start audio capture: \(error.localizedDescription)")
            AudioDeviceDestroyIOProcID(self.aggregateDevice.id, ioProcID)
            self.ioProcID = nil
            continuation.finish()
            self.continuation = nil
        }

        return stream
    }

    /// Stops capturing and tears down the tap.
    func stop() {
        if let ioProcID = self.ioProcID {
            if self.isRunning {
                try? self.aggregateDevice.stop(IOProcID: ioProcID)
            }
            AudioDeviceDestroyIOProcID(self.aggregateDevice.id, ioProcID)
            self.ioProcID = nil
            self.isRunning = false
        }

        self.continuation?.finish()
        self.continuation = nil

        try? self.system.destroyProcessTap(self.tap)
        try? self.system.destroyAggregateDevice(self.aggregateDevice)
    }
}

// MARK: - TapSink

/// Bridges the real-time Core Audio callback into the async stream the encoder reads.
///
/// The callback runs on a real-time thread, so it only flattens the delivered buffers and hands
/// them to the stream; encoding and networking happen on the consumer side.
private final class TapSink: @unchecked Sendable {
    private let layout: AudioTapFormatLayout
    private let continuation: AsyncStream<AudioTapBuffer>.Continuation

    init(layout: AudioTapFormatLayout, continuation: AsyncStream<AudioTapBuffer>.Continuation) {
        self.layout = layout
        self.continuation = continuation
    }

    /// Copies the delivered audio out of Core Audio's buffers and yields it.
    func consume(_ bufferList: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard list.count == self.layout.bufferCount else { return }

        var payload = Data()
        var byteSizes: [Int] = []

        for index in 0 ..< list.count {
            let buffer = list[index]
            let byteCount = Int(buffer.mDataByteSize)
            guard byteCount > 0, let data = buffer.mData else {
                byteSizes.append(0)
                continue
            }

            payload.append(data.assumingMemoryBound(to: UInt8.self), count: byteCount)
            byteSizes.append(byteCount)
        }

        guard !payload.isEmpty, let frameCount = self.layout.frameCount(forBufferByteSizes: byteSizes) else {
            return
        }

        self.continuation.yield(
            AudioTapBuffer(
                payload: payload,
                bufferByteSizes: byteSizes,
                frameCount: frameCount
            )
        )
    }
}
