import Foundation
import Testing
@testable import Kaset

/// Tap-process selection for Cast audio capture.
///
/// These tests pin the layout that broke casting: WebKit renders playback audio in XPC helper
/// services whose parent is `launchd`, so they are absent from the app's process tree and must be
/// selected from Core Audio's process list instead.
@Suite(.tags(.service))
struct CastAudioProcessResolverTests {
    // MARK: - Selection

    @Test("Taps the app and everything below it")
    func tapsAppAndDescendants() {
        let resolution = CastAudioProcessResolver.resolve(
            Inputs.fixture(
                descendants: [fixtureCandidate(pid: 42, name: "Kaset Helper")],
                includesWebKitHelpers: false
            )
        )

        #expect(resolution.processIDs == [Inputs.ownPID, 42])
    }

    @Test("Taps WebKit helpers that are not in the process tree")
    func tapsWebKitHelpersOutsideTheProcessTree() {
        // A helper's parent is launchd, so nothing in the tree points at it. Without this case the
        // tap would cover only the app process, capture silence, and leave the Mac audible.
        let resolution = CastAudioProcessResolver.resolve(
            Inputs.fixture(
                audioProcesses: [
                    fixtureCandidate(pid: 200, name: "com.apple.WebKit.GPU", isRunningOutput: true, isWebKitHelper: true),
                    fixtureCandidate(pid: 201, name: "com.apple.WebKit.WebContent", isWebKitHelper: true),
                ],
                includesWebKitHelpers: true
            )
        )

        #expect(resolution.processIDs == [Inputs.ownPID, 200, 201])
        #expect(resolution.didSelectWebKitHelpers)
        #expect(resolution.playingCandidates.map(\.pid) == [200])
    }

    @Test("Leaves WebKit helpers alone when the caller does not ask for them")
    func omitsWebKitHelpersWhenNotRequested() {
        let resolution = CastAudioProcessResolver.resolve(
            Inputs.fixture(
                audioProcesses: [
                    fixtureCandidate(pid: 200, isRunningOutput: true, isWebKitHelper: true),
                ],
                includesWebKitHelpers: false
            )
        )

        #expect(resolution.processIDs == [Inputs.ownPID])
        #expect(!resolution.didSelectWebKitHelpers)
    }

    @Test("Taps processes Core Audio attributes to the app's bundle identifier")
    func tapsProcessesAttributedToTheAppBundle() {
        let resolution = CastAudioProcessResolver.resolve(
            Inputs.fixture(
                audioProcesses: [
                    fixtureCandidate(pid: 300, name: "com.apple.WebKit.GPU", bundleID: Inputs.appBundleID),
                ],
                includesWebKitHelpers: false
            )
        )

        #expect(resolution.processIDs == [Inputs.ownPID, 300])
    }

    @Test("Ignores processes that belong to other applications")
    func ignoresOtherApplications() {
        let resolution = CastAudioProcessResolver.resolve(
            Inputs.fixture(
                audioProcesses: [
                    fixtureCandidate(pid: 400, name: "Music", bundleID: "com.apple.Music", isRunningOutput: true),
                    fixtureCandidate(pid: 401, name: "Safari", bundleID: "com.apple.Safari", isRunningOutput: true),
                ],
                includesWebKitHelpers: false
            )
        )

        #expect(resolution.processIDs == [Inputs.ownPID])
    }

    @Test("Does not match attributed processes without a bundle identifier to match on")
    func requiresABundleIdentifierForAttribution() {
        let inputs = CastAudioProcessResolver.Inputs(
            ownProcess: fixtureCandidate(pid: Inputs.ownPID),
            ownBundleID: nil,
            descendants: [],
            audioProcesses: [fixtureCandidate(pid: 500, bundleID: nil, isRunningOutput: true)],
            includesWebKitHelpers: false
        )

        #expect(CastAudioProcessResolver.resolve(inputs).processIDs == [Inputs.ownPID])
    }

    @Test("Taps each process once when the signals overlap")
    func deduplicatesOverlappingSignals() {
        let shared = fixtureCandidate(
            pid: 600,
            name: "com.apple.WebKit.GPU",
            bundleID: Inputs.appBundleID,
            isRunningOutput: true,
            isWebKitHelper: true
        )

        let resolution = CastAudioProcessResolver.resolve(
            Inputs.fixture(
                descendants: [shared],
                audioProcesses: [shared],
                includesWebKitHelpers: true
            )
        )

        #expect(resolution.processIDs == [Inputs.ownPID, 600])
    }

    // MARK: - Metadata

    @Test("Describes a process tree process with what Core Audio knows about it")
    func mergesCoreAudioMetadata() {
        let resolution = CastAudioProcessResolver.resolve(
            Inputs.fixture(
                descendants: [fixtureCandidate(pid: 42, name: "Kaset Helper")],
                audioProcesses: [
                    fixtureCandidate(pid: 42, name: "afplay", bundleID: "com.apple.afplay", isRunningOutput: true),
                ],
                includesWebKitHelpers: false
            )
        )

        let merged = resolution.candidates.last
        #expect(merged?.name == "Kaset Helper")
        #expect(merged?.bundleID == "com.apple.afplay")
        #expect(merged?.isRunningOutput == true)
    }

    @Test("Uses Core Audio's description of the app process when it reports one")
    func mergesCoreAudioMetadataForTheAppProcess() throws {
        let resolution = CastAudioProcessResolver.resolve(
            Inputs.fixture(
                audioProcesses: [fixtureCandidate(pid: Inputs.ownPID, bundleID: Inputs.appBundleID, isRunningOutput: true)],
                includesWebKitHelpers: false
            )
        )

        let ownProcess = try #require(resolution.candidates.first)
        #expect(ownProcess.pid == Inputs.ownPID)
        #expect(ownProcess.bundleID == Inputs.appBundleID)
        #expect(ownProcess.isRunningOutput)
    }

    // MARK: - Helper Recognition

    @Test("Recognises WebKit helpers by bundle identifier or by executable path")
    func recognisesWebKitHelpers() {
        #expect(CastAudioProcessResolver.isWebKitHelper(bundleID: "com.apple.WebKit.GPU", executionPath: nil))
        #expect(CastAudioProcessResolver.isWebKitHelper(
            bundleID: nil,
            executionPath: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/"
                + "com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"
        ))
    }

    @Test("Does not mistake other applications for WebKit helpers")
    func ignoresNonHelperProcesses() {
        #expect(!CastAudioProcessResolver.isWebKitHelper(bundleID: "com.apple.Safari", executionPath: nil))
        #expect(!CastAudioProcessResolver.isWebKitHelper(bundleID: nil, executionPath: nil))
        #expect(!CastAudioProcessResolver.isWebKitHelper(
            bundleID: nil,
            executionPath: "/Applications/Kaset.app/Contents/MacOS/Kaset"
        ))
    }

    @Test("Taps a silent helper, because it may start playing after the tap is built")
    func tapsSilentHelpers() {
        // Tapping a silent process costs nothing; missing the helper when playback starts later would
        // leave the Cast device with an empty stream.
        let resolution = CastAudioProcessResolver.resolve(
            Inputs.fixture(
                audioProcesses: [fixtureCandidate(pid: 700, isWebKitHelper: true)],
                includesWebKitHelpers: true
            )
        )

        #expect(resolution.processIDs == [Inputs.ownPID, 700])
        #expect(resolution.playingCandidates.isEmpty)
    }

    @Test("Includes every WebKit helper, which is the documented trade-off")
    func includesEveryWebKitHelper() {
        // Known limitation: another WebKit application playing at the same time is captured as well.
        // It is a deliberate trade — silence is the failure this selection exists to prevent.
        let resolution = CastAudioProcessResolver.resolve(
            Inputs.fixture(
                audioProcesses: [
                    fixtureCandidate(pid: 801, name: "com.apple.WebKit.GPU", isRunningOutput: true, isWebKitHelper: true),
                ],
                includesWebKitHelpers: true
            )
        )

        #expect(resolution.didSelectWebKitHelpers)
        #expect(resolution.processIDs.count == 2)
    }

    // MARK: - Live System

    @Test("Reads the live process state and always taps the app itself")
    func readsLiveProcessState() {
        // Exercises the Core Audio and process-tree adapter against the running machine, where every
        // property is throwing and a failure drops the process rather than the tap.
        let inputs = CastAudioProcesses.current(
            ownPID: getpid(),
            ownBundleID: "test.kaset.cast",
            includesWebKitHelpers: true
        )

        #expect(inputs.ownProcess.pid == getpid())
        #expect(inputs.ownBundleID == "test.kaset.cast")

        let resolution = CastAudioProcessResolver.resolve(inputs)
        #expect(resolution.processIDs.contains(getpid()))
        #expect(Set(resolution.processIDs).count == resolution.processIDs.count)
    }
}

// MARK: - Fixtures

/// Builds a candidate for the resolver tests.
private func fixtureCandidate(
    pid: pid_t,
    name: String = "Kaset",
    bundleID: String? = nil,
    isRunningOutput: Bool = false,
    isWebKitHelper: Bool = false
) -> CastAudioProcessCandidate {
    CastAudioProcessCandidate(
        pid: pid,
        name: name,
        bundleID: bundleID,
        isRunningOutput: isRunningOutput,
        isWebKitHelper: isWebKitHelper
    )
}

private struct Inputs {
    static let ownPID: pid_t = 1000
    static let appBundleID = "com.popcornfuzzy.kaset"

    /// Inputs with the app process present, so each test only states what it varies.
    static func fixture(
        descendants: [CastAudioProcessCandidate] = [],
        audioProcesses: [CastAudioProcessCandidate] = [],
        includesWebKitHelpers: Bool
    ) -> CastAudioProcessResolver.Inputs {
        CastAudioProcessResolver.Inputs(
            ownProcess: fixtureCandidate(pid: self.ownPID, bundleID: self.appBundleID),
            ownBundleID: self.appBundleID,
            descendants: descendants,
            audioProcesses: audioProcesses,
            includesWebKitHelpers: includesWebKitHelpers
        )
    }
}
