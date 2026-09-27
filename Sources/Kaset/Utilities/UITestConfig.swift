import Darwin
import Foundation

/// Launch arguments and environment keys for UI testing.
/// Use these to configure the app in test mode with mock data.
enum UITestConfig {
    // MARK: - Launch Arguments

    /// When present, app runs in UI test mode with mock services.
    static let uiTestModeArgument = "-UITestMode"

    /// When present, skip onboarding and assume logged in.
    static let skipAuthArgument = "-SkipAuth"

    // MARK: - Environment Keys

    /// JSON-encoded mock home sections data.
    static let mockHomeSectionsKey = "MOCK_HOME_SECTIONS"

    /// JSON-encoded mock search results data.
    static let mockSearchResultsKey = "MOCK_SEARCH_RESULTS"

    /// JSON-encoded mock playlists data.
    static let mockPlaylistsKey = "MOCK_PLAYLISTS"

    /// JSON-encoded mock current track data.
    static let mockCurrentTrackKey = "MOCK_CURRENT_TRACK"

    /// Whether player should simulate playing state.
    static let mockIsPlayingKey = "MOCK_IS_PLAYING"

    /// Whether the current track has video available.
    static let mockHasVideoKey = "MOCK_HAS_VIDEO"

    /// JSON-encoded mock favorites data.
    static let mockFavoritesKey = "MOCK_FAVORITES"

    /// JSON-encoded mock accounts data for account switcher UI tests.
    static let mockAccountsKey = "MOCK_ACCOUNTS"

    /// When true, simulate account switch failure in UI tests.
    static let mockAccountSwitchFailKey = "MOCK_ACCOUNT_SWITCH_FAIL"

    /// When true, add delay to account loading to surface loading UI in tests.
    static let mockAccountLoadingDelayKey = "MOCK_ACCOUNT_LOADING_DELAY"

    /// When true, force logged-out state in UI tests.
    static let mockLoggedOutKey = "MOCK_LOGGED_OUT"

    // MARK: - Detection

    /// Returns true if the app was launched in UI test mode.
    ///
    /// The launch argument and environment variable above are what CI uses. They are not enough on a
    /// developer machine: the UI test runner is sandboxed, so macOS drops both when it opens the app
    /// through `NSWorkspace`, and the app runs against the signed-in account instead of the mock
    /// client. The marker file below survives that launch, because the app has a read-write
    /// entitlement for its own application-support directory. `Scripts/run-ui-tests.sh` creates it
    /// for the duration of a run.
    static var isUITestMode: Bool {
        CommandLine.arguments.contains(uiTestModeArgument)
            || ProcessInfo.processInfo.environment["UI_TEST_MODE"] == "1"
            || self.uiTestModeMarkerURLs.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Marker files that turn on UI test mode when they exist. See `isUITestMode`.
    ///
    /// Both candidates are checked because the two sides see different home directories: the app is
    /// sandboxed, so its application-support directory is inside its container, while
    /// `Scripts/run-ui-tests.sh` can only write the real home directory.
    static var uiTestModeMarkerURLs: [URL] {
        var candidates: [URL] = []

        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(support.appending(path: "Kaset/UITestMode"))
        }

        if let home = self.realHomeDirectory {
            candidates.append(home.appending(path: "Library/Application Support/Kaset/UITestMode"))
        }

        return candidates
    }

    /// File the app writes when it comes up in UI test mode, next to the marker above.
    ///
    /// `Scripts/run-ui-tests.sh` removes it before a run and checks it afterwards, so a run that
    /// silently went to the real account is reported instead of looking like a test-data bug. The log
    /// cannot be used for that: the info-level entries of a freshly built app are not flushed to the
    /// log store for minutes, so the check would fail on runs that are in fact in UI test mode.
    static var uiTestModeSeenURL: URL? {
        self.realHomeDirectory?.appending(path: "Library/Application Support/Kaset/UITestModeSeen")
    }

    /// Records that the app came up in UI test mode, for the UI test script to check.
    static func markUITestModeSeen() {
        guard let url = self.uiTestModeSeenURL else { return }
        try? Data(dateLabel.utf8).write(to: url, options: .atomic)
    }

    private static var dateLabel: String {
        ISO8601DateFormatter().string(from: Date())
    }

    /// The account's home directory. `NSHomeDirectory()` points at the app's container while the app
    /// is sandboxed, so the passwd database is the way back to the real home directory.
    private static var realHomeDirectory: URL? {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: directory))
    }

    /// Returns true if running inside XCTest (unit tests).
    /// Checks for XCTestCase class presence at runtime.
    static var isRunningUnitTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// Returns true if auth should be skipped (simulate logged in).
    ///
    /// Implied by UI test mode: the tests are meant to run against a fake account, and restoring the
    /// real session would reach for the Keychain, which macOS gates behind a user prompt.
    static var shouldSkipAuth: Bool {
        CommandLine.arguments.contains(skipAuthArgument)
            || ProcessInfo.processInfo.environment["SKIP_AUTH"] == "1"
            || self.isUITestMode
    }

    /// Returns environment value for given key.
    static func environmentValue(for key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }
}
