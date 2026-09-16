import CoreAudio
import Darwin
import Foundation

// MARK: - CastAudioProcessCandidate

/// A process that could be contributing audio to what the user hears.
///
/// Core Audio only knows about processes that have used the audio hardware, so this carries both
/// what Core Audio reports and what the process tree reports.
struct CastAudioProcessCandidate: Sendable, Equatable {
    /// Process identifier.
    let pid: pid_t

    /// Executable name, when the process tree knows it.
    let name: String

    /// Bundle identifier Core Audio attributes to the process, when any.
    let bundleID: String?

    /// Whether the process is currently sending audio to an output device.
    let isRunningOutput: Bool

    /// Whether the process is one of WebKit's XPC helper services.
    let isWebKitHelper: Bool

    /// Short description used in diagnostics.
    var diagnosticDescription: String {
        var description = "\(self.pid)"
        if !self.name.isEmpty {
            description += " \(self.name)"
        }
        if let bundleID {
            description += " [\(bundleID)]"
        }
        if self.isRunningOutput {
            description += " (playing)"
        }
        return description
    }
}

// MARK: - CastAudioProcessResolver

/// Works out which processes an audio tap has to cover to capture Kaset's audio.
///
/// This exists because of how WebKit plays audio. The sound a WKWebView makes is rendered by
/// WebKit's XPC helper services — `com.apple.WebKit.GPU` in practice — and those helpers are
/// launched by `launchd`, **not** by the app. Their parent is therefore PID 1, they never appear in
/// the app's process tree, and tapping `getpid()` plus its descendants captures silence.
///
/// The resolver combines every signal available without private APIs:
///
/// 1. The app process itself.
/// 2. Descendants of the app process, which covers any layout where helpers *are* children.
/// 3. Processes Core Audio attributes to the app's bundle identifier.
/// 4. WebKit's helper services, which cannot be attributed by ancestry, when the caller says the
///    app's audio comes from WebKit.
///
/// Step 4 is deliberately broad. Tapping a helper that is silent costs nothing — it contributes no
/// audio and muting a silent process is a no-op — whereas *missing* the helper means the Cast device
/// receives an empty stream. The known trade-off is that audio from another WebKit-based app that is
/// playing at the same time is captured too; see `docs/adr/0015-chromecast-audio-casting.md`.
enum CastAudioProcessResolver {
    /// Everything the resolver needs to decide.
    struct Inputs: Sendable, Equatable {
        /// The app's own process.
        var ownProcess: CastAudioProcessCandidate

        /// Bundle identifier of the app, used to recognise processes Core Audio attributes to it.
        var ownBundleID: String?

        /// Processes descended from the app process.
        var descendants: [CastAudioProcessCandidate]

        /// Every process Core Audio currently knows about.
        var audioProcesses: [CastAudioProcessCandidate]

        /// Whether WebKit's helper services should be tapped as well.
        var includesWebKitHelpers: Bool
    }

    /// The processes to tap, in the order they were selected.
    struct Resolution: Sendable, Equatable {
        /// Processes that will be handed to the tap.
        var candidates: [CastAudioProcessCandidate]

        /// Whether WebKit helpers contributed processes.
        var didSelectWebKitHelpers: Bool

        /// Process identifiers to tap, deduplicated.
        var processIDs: [pid_t] {
            self.candidates.map(\.pid)
        }

        /// Processes in the set that are currently producing audio.
        var playingCandidates: [CastAudioProcessCandidate] {
            self.candidates.filter(\.isRunningOutput)
        }

        /// Description of the selected processes for diagnostics.
        var diagnosticDescription: String {
            self.candidates.map(\.diagnosticDescription).joined(separator: ", ")
        }
    }

    /// Selects the processes to tap.
    static func resolve(_ inputs: Inputs) -> Resolution {
        var selected: [CastAudioProcessCandidate] = []
        var seen = Set<pid_t>()

        /// Appends a process once, preferring the metadata Core Audio reports for it.
        func append(_ candidate: CastAudioProcessCandidate) {
            guard seen.insert(candidate.pid).inserted else { return }
            selected.append(self.merged(candidate, with: inputs.audioProcesses))
        }

        append(inputs.ownProcess)
        for descendant in inputs.descendants {
            append(descendant)
        }

        if let ownBundleID = inputs.ownBundleID {
            for process in inputs.audioProcesses where process.bundleID == ownBundleID {
                append(process)
            }
        }

        var didSelectWebKitHelpers = false
        if inputs.includesWebKitHelpers {
            for helper in inputs.audioProcesses where helper.isWebKitHelper {
                append(helper)
                didSelectWebKitHelpers = true
            }
        }

        return Resolution(candidates: selected, didSelectWebKitHelpers: didSelectWebKitHelpers)
    }

    // MARK: - Helpers

    /// Overlays what Core Audio knows onto a process the process tree described.
    ///
    /// The process tree supplies names but no audio state, so the audio description wins where both
    /// describe the same process.
    private static func merged(
        _ candidate: CastAudioProcessCandidate,
        with audioProcesses: [CastAudioProcessCandidate]
    ) -> CastAudioProcessCandidate {
        guard let audio = audioProcesses.first(where: { $0.pid == candidate.pid }) else {
            return candidate
        }

        return CastAudioProcessCandidate(
            pid: candidate.pid,
            name: candidate.name.isEmpty ? audio.name : candidate.name,
            bundleID: candidate.bundleID ?? audio.bundleID,
            isRunningOutput: audio.isRunningOutput,
            isWebKitHelper: candidate.isWebKitHelper || audio.isWebKitHelper
        )
    }

    /// Whether a process is one of WebKit's XPC helper services.
    ///
    /// Helper services are identified by bundle identifier where Core Audio reports one, and by
    /// executable path otherwise, since a helper that has not yet used the audio hardware can be
    /// reported without a bundle identifier.
    static func isWebKitHelper(bundleID: String?, executionPath: String?) -> Bool {
        if let bundleID, bundleID.hasPrefix("com.apple.WebKit.") {
            return true
        }

        guard let executionPath else { return false }
        return executionPath.contains("WebKit.framework") && executionPath.contains(".xpc/Contents/MacOS/")
    }
}

// MARK: - CastAudioProcesses

/// Reads the live process state the resolver works from.
enum CastAudioProcesses {
    /// Gathers the processes that could be producing Kaset's audio.
    ///
    /// - Parameters:
    ///   - ownPID: The app's process identifier.
    ///   - ownBundleID: The app's bundle identifier.
    ///   - includesWebKitHelpers: Whether WebKit's helper services should be tapped. True whenever
    ///     casting, because every sound Kaset makes is rendered by WebKit.
    ///   - tree: Snapshot of the process tree, read from the system when not supplied.
    ///   - audioProcesses: Snapshot of Core Audio's processes, read from the system when not supplied.
    static func current(
        ownPID: pid_t = getpid(),
        ownBundleID: String? = Bundle.main.bundleIdentifier,
        includesWebKitHelpers: Bool,
        tree: [ProcessTree.Entry]? = nil,
        audioProcesses: [AudioHardwareProcess]? = nil
    ) -> CastAudioProcessResolver.Inputs {
        let entries = tree ?? ProcessTree.entries()
        let namesByPID = Dictionary(entries.map { ($0.pid, $0.name) }, uniquingKeysWith: { first, _ in first })

        // Reading Core Audio's processes fails when the audio system is unavailable, which leaves the
        // tap covering only the process tree. Every property on a Core Audio process is throwing, and
        // a process that cannot be described cannot be tapped either, so failures drop the process.
        let hardwareProcesses = audioProcesses ?? (try? AudioHardwareSystem.shared.processes) ?? []
        let candidates = hardwareProcesses.compactMap { process -> CastAudioProcessCandidate? in
            guard let pid = try? process.pid else { return nil }

            let bundleID = (try? process.bundleID) ?? nil
            return CastAudioProcessCandidate(
                pid: pid,
                name: namesByPID[pid] ?? "",
                bundleID: bundleID,
                isRunningOutput: (try? process.isRunningOutput) ?? false,
                isWebKitHelper: CastAudioProcessResolver.isWebKitHelper(
                    bundleID: bundleID,
                    executionPath: self.executionPath(of: pid)
                )
            )
        }

        let ownProcess = candidates.first { $0.pid == ownPID }
            ?? CastAudioProcessCandidate(
                pid: ownPID,
                name: namesByPID[ownPID] ?? "Kaset",
                bundleID: ownBundleID,
                isRunningOutput: false,
                isWebKitHelper: false
            )

        let descendants = ProcessTree.descendantProcessIDs(of: ownPID).map { pid in
            candidates.first { $0.pid == pid }
                ?? CastAudioProcessCandidate(
                    pid: pid,
                    name: namesByPID[pid] ?? "",
                    bundleID: nil,
                    isRunningOutput: false,
                    isWebKitHelper: false
                )
        }

        return CastAudioProcessResolver.Inputs(
            ownProcess: ownProcess,
            ownBundleID: ownBundleID,
            descendants: descendants,
            audioProcesses: candidates,
            includesWebKitHelpers: includesWebKitHelpers
        )
    }

    /// Absolute path of a process's executable.
    ///
    /// `proc_pidpath` fails for processes this user may not inspect, which is fine: those processes
    /// cannot be tapped either.
    private static func executionPath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }

        return String(decoding: buffer[0 ..< Int(length)], as: UTF8.self)
    }
}
