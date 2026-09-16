import Foundation

// MARK: - CastAudioStreamerError

/// Errors raised while preparing the audio stream.
enum CastAudioStreamerError: LocalizedError {
    /// No local interface could be found for the device to dial back to.
    case noLocalAddress

    var errorDescription: String? {
        switch self {
        case .noLocalAddress:
            "No local network address is available to send audio from."
        }
    }
}

// MARK: - CastAudioStreamer

/// Captures Kaset's audio, encodes it, and serves it to the Cast device.
///
/// The pipeline is deliberately independent from YouTube: the audio is captured after WebKit has
/// decoded it, so DRM-protected playback, podcasts, and ads all cast exactly as they play locally.
@MainActor
final class CastAudioStreamer {
    /// How long capture may stay silent before that is worth reporting.
    ///
    /// Silence is the hard failure mode of this pipeline: the receiver happily plays an empty stream
    /// and shows a spinner forever, so an unsilent log entry is the fastest way to tell a broken tap
    /// apart from a broken receiver.
    private static let captureWatchdogDelay: Duration = .seconds(5)

    /// How often capture totals are reported while streaming.
    private static let captureReportInterval: Duration = .seconds(10)

    private let server: LocalAudioStreamServer
    private var tap: AudioProcessTap?
    private var encoder: AACStreamEncoder?
    private var consumerTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    /// Whether any audio has reached the encoder since capture started.
    private var hasCapturedAudio = false

    /// Whether any captured buffer has carried audio rather than digital silence.
    private var hasCapturedAudibleAudio = false

    private var capturedFrameCount = 0
    private var streamedByteCount = 0

    init(server: LocalAudioStreamServer = LocalAudioStreamServer()) {
        self.server = server
    }

    /// Path the receiver requests, e.g. `/kaset-cast.aac`.
    var streamPath: String {
        self.server.streamPath
    }

    /// Whether the receiver is currently reading the stream.
    var isReceiverConnected: Bool {
        self.server.streamingClientCount > 0
    }

    /// Called when the receiver connects to or leaves the stream.
    var onReceiverConnectionChanged: ((Bool) -> Void)?

    /// Starts the pipeline and returns the URL the Cast device should play.
    ///
    /// - Parameter preferredLocalAddress: Address the control connection is using, which is the one
    ///   the device can dial back. Falls back to subnet matching when it is unavailable.
    func start(deviceHost: String, preferredLocalAddress: String? = nil) async throws -> URL {
        self.server.onStreamingClientCountChanged = { [weak self] count in
            self?.onReceiverConnectionChanged?(count > 0)
        }

        let port = try await self.server.start()

        let candidates = CastStreamAddress.localIPv4Addresses()
        guard let localAddress = preferredLocalAddress
            ?? CastStreamAddress.bestAddress(forDeviceHost: deviceHost, candidates: candidates)
        else {
            self.server.stop()
            throw CastAudioStreamerError.noLocalAddress
        }

        DiagnosticsLogger.cast.info(
            "Serving the stream from \(localAddress) (local addresses: \(candidates.map(\.address).joined(separator: ", ")))"
        )

        // WebKit renders playback audio in its own XPC helper services, and `launchd` — not the app —
        // is their parent. They are therefore invisible to the process tree, so the tap set has to be
        // resolved from Core Audio's process list. See ``CastAudioProcessResolver``.
        let inputs = CastAudioProcesses.current(includesWebKitHelpers: true)
        let selection = CastAudioProcessResolver.resolve(inputs)
        self.logSelection(inputs: inputs, selection: selection)

        let tap = try AudioProcessTap(processIDs: selection.processIDs)
        self.logTapCoverage(selection: selection, tapped: tap.tappedProcessIDs)
        let encoder = try AACStreamEncoder(anyFormat: tap.format)

        self.tap = tap
        self.encoder = encoder
        self.hasCapturedAudio = false
        self.hasCapturedAudibleAudio = false
        self.capturedFrameCount = 0
        self.streamedByteCount = 0

        let audioStream = tap.start()
        self.consume(audioStream, selection: selection)

        guard let url = URL(string: "http://\(localAddress):\(port)\(self.server.streamPath)") else {
            throw CastAudioStreamerError.noLocalAddress
        }

        DiagnosticsLogger.cast.info("Audio stream available at \(url.absoluteString)")
        return url
    }

    /// Stops capture, encoding, and serving.
    func stop() {
        self.consumerTask?.cancel()
        self.consumerTask = nil
        self.watchdogTask?.cancel()
        self.watchdogTask = nil

        self.tap?.stop()
        self.tap = nil
        self.encoder = nil

        self.server.stop()
    }

    // MARK: - Capture

    /// Encodes captured audio and hands it to the stream server.
    private func consume(_ audioStream: AsyncStream<AudioTapBuffer>, selection: CastAudioProcessResolver.Resolution) {
        self.startCaptureWatchdog(selection: selection)

        self.consumerTask = Task { [weak self] in
            var nextReport = ContinuousClock.now.advanced(by: Self.captureReportInterval)

            for await buffer in audioStream {
                guard let self, let encoder = self.encoder else { return }

                do {
                    let encoded = try encoder.encode(buffer)
                    self.noteCaptured(buffer, bytes: encoded.count)

                    guard !encoded.isEmpty else { continue }
                    self.server.enqueue(encoded)
                } catch {
                    DiagnosticsLogger.cast.error("Audio encoding failed: \(error.localizedDescription)")
                }

                if ContinuousClock.now >= nextReport {
                    nextReport = ContinuousClock.now.advanced(by: Self.captureReportInterval)
                    DiagnosticsLogger.cast.debug(
                        "Captured \(self.capturedFrameCount) frames and streamed \(self.streamedByteCount) bytes so far"
                    )
                }
            }

            guard let self, self.capturedFrameCount > 0 else { return }
            DiagnosticsLogger.cast.info(
                "Audio capture ended after \(self.capturedFrameCount) frames (\(self.streamedByteCount) bytes streamed)"
            )
        }
    }

    /// Records a captured buffer and reports the first one.
    private func noteCaptured(_ buffer: AudioTapBuffer, bytes: Int) {
        self.capturedFrameCount += buffer.frameCount
        self.streamedByteCount += bytes

        if !buffer.isSilent {
            self.hasCapturedAudibleAudio = true
        }

        guard !self.hasCapturedAudio else { return }
        self.hasCapturedAudio = true
        DiagnosticsLogger.cast.info("Captured the first buffer from the audio tap (\(buffer.frameCount) frames)")
    }

    /// Reports a tap that produced no audio, or only silence, which is otherwise indistinguishable from a
    /// receiver that never started playing.
    private func startCaptureWatchdog(selection: CastAudioProcessResolver.Resolution) {
        self.watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: Self.captureWatchdogDelay)
            guard !Task.isCancelled, let self else { return }

            let seconds = Self.captureWatchdogDelay.components.seconds

            guard self.hasCapturedAudio else {
                let hint = "If the track had not started playing yet, stop casting and start it again while it plays."
                DiagnosticsLogger.cast.warning(
                    "The audio tap has captured nothing \(seconds)s after starting. Tapped: \(selection.diagnosticDescription). \(hint)"
                )
                return
            }

            // A tap without the system audio recording permission does everything except carry audio: it
            // starts, mutes the processes it covers, and delivers silence.
            guard !self.hasCapturedAudibleAudio else { return }
            DiagnosticsLogger.cast.warning(
                "The audio tap has delivered only silence \(seconds)s after starting. Grant Kaset audio recording permission in System Settings → Privacy & Security → Screen & System Audio Recording, then cast again."
            )
        }
    }

    // MARK: - Diagnostics

    /// Reports which processes were chosen and what they were doing at the time.
    private func logSelection(
        inputs: CastAudioProcessResolver.Inputs,
        selection: CastAudioProcessResolver.Resolution
    ) {
        let playing = inputs.audioProcesses.filter(\.isRunningOutput)
        let playingDescription = playing.isEmpty
            ? "none"
            : playing.map(\.diagnosticDescription).joined(separator: ", ")
        DiagnosticsLogger.cast.debug(
            "Core Audio reports \(playing.count) process(es) playing: \(playingDescription)"
        )

        DiagnosticsLogger.cast.info(
            "Tapping \(selection.candidates.count) process(es) for audio capture: \(selection.diagnosticDescription)"
        )

        if selection.playingCandidates.isEmpty {
            DiagnosticsLogger.cast.debug(
                "No tapped process is playing yet; capture starts as soon as audio begins."
            )
        }
    }

    /// Reports processes that were requested for tapping but that Core Audio does not know about.
    private func logTapCoverage(
        selection: CastAudioProcessResolver.Resolution,
        tapped: [pid_t]
    ) {
        let missing = Set(selection.processIDs).subtracting(tapped).sorted()
        guard !missing.isEmpty else { return }

        let missingDescription = missing.map(String.init).joined(separator: ", ")
        DiagnosticsLogger.cast.warning(
            "Core Audio has no audio process for \(missingDescription); those processes cannot be captured."
        )
    }
}
