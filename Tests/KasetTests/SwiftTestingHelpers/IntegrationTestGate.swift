import Foundation
import Testing

/// Whether the suites that drive the machine's **on-device model** run.
///
/// `MusicIntentIntegrationTests` is the only suite whose result depends on a language model's phrasing rather
/// than the app's own logic, and the only one that costs seconds per test: 16 tests, each call taking a few
/// seconds on the model, each retrying up to three times when an assertion misses. Measured on a 10-core Mac:
/// 66 seconds on its own, against 36 seconds for the other 1779 tests together — and the load it puts on the
/// machine is why timing-sensitive suites elsewhere in the same run (the local Cast stream server, the artist
/// library reconciliation) flaked while it was going.
///
/// So it is opt-in, and run the way it is meant to be run — deliberately, and on its own:
///
/// ```bash
/// KASET_INTEGRATION_TESTS=1 swift test --skip KasetUITests --filter MusicIntentIntegrationTests
/// ```
///
/// The tags stay on the suite (`.integration`, `.slow`), so the Xcode test navigator groups it and
/// `-only-testing:` still reaches it.
enum IntegrationTestGate {
    /// Whether the on-device model suites were asked for.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["KASET_INTEGRATION_TESTS"] == "1"
    }

    /// What the suite states about itself when it is skipped, so a run that skips it says why.
    static let requirement: Comment = "run with KASET_INTEGRATION_TESTS=1: the on-device model suites are opt-in"
}
