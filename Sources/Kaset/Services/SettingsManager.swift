import Foundation
import Observation

/// Manages user preferences persisted via UserDefaults.
@MainActor
@Observable
final class SettingsManager {
    static let shared = SettingsManager()

    // MARK: - Settings Keys

    private enum Keys {
        static let showNowPlayingNotifications = "settings.showNowPlayingNotifications"
        static let defaultLaunchPage = "settings.defaultLaunchPage"
        static let hapticFeedbackEnabled = "settings.hapticFeedbackEnabled"
        static let rememberPlaybackSettings = "settings.rememberPlaybackSettings"
        static let lastFMEnabled = "settings.lastFMEnabled"
        static let enabledServices = "settings.enabledServices"
        static let scrobblePercentThreshold = "settings.scrobblePercentThreshold"
        static let scrobbleMinSeconds = "settings.scrobbleMinSeconds"
        static let mediaControlStyle = "settings.mediaControlStyle"
        static let syncedLyricsEnabled = "settings.syncedLyricsEnabled"
        /// Legacy single-choice preset, kept only to migrate into the per-provider model.
        static let lyricsProvider = "settings.lyricsProvider"
        static let lyricsProviderOrder = "settings.lyricsProviderOrder"
        static let lyricsDisabledProviders = "settings.lyricsDisabledProviders"
        static let safeAdBlockingEnabled = "settings.safeAdBlockingEnabled"
        static let animatedCanvasEnabled = "settings.animatedCanvasEnabled"
    }

    // MARK: - Launch Page Options

    /// Available pages to launch the app with.
    enum LaunchPage: String, CaseIterable, Identifiable {
        case home
        case explore
        case charts
        case moodsAndGenres
        case newReleases
        case likedMusic
        case playlists
        case lastUsed

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .home: String(localized: "Home")
            case .explore: String(localized: "Explore")
            case .charts: String(localized: "Charts")
            case .moodsAndGenres: String(localized: "Moods & Genres")
            case .newReleases: String(localized: "New Releases")
            case .likedMusic: String(localized: "Liked Music")
            case .playlists: String(localized: "Playlists")
            case .lastUsed: String(localized: "Last Used")
            }
        }

        /// Converts LaunchPage to NavigationItem for navigation.
        var navigationItem: NavigationItem {
            switch self {
            case .home: .home
            case .explore: .explore
            case .charts: .charts
            case .moodsAndGenres: .moodsAndGenres
            case .newReleases: .newReleases
            case .likedMusic: .likedMusic
            case .playlists: .library
            case .lastUsed: .home // Fallback, actual value comes from lastUsedPage
            }
        }
    }

    // MARK: - Media Control Style

    /// Controls which buttons appear in the Now Playing widget (Control Center).
    enum MediaControlStyle: String, CaseIterable, Identifiable {
        case skipForwardBackward
        case nextPreviousTrack

        var id: String {
            rawValue
        }

        var displayName: String {
            switch self {
            case .skipForwardBackward: "Skip Forward/Backward"
            case .nextPreviousTrack: "Next/Previous Track"
            }
        }
    }

    // MARK: - Lyrics Providers

    /// A lyrics source the user can enable, disable, and reorder. Position in
    /// the order defines priority when capabilities tie.
    enum LyricsProviderID: String, CaseIterable, Identifiable, Codable, Sendable {
        case betterLyrics
        case paxsenix
        case kugou
        case lrclib

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .betterLyrics: "BetterLyrics"
            case .paxsenix: "Paxsenix"
            case .kugou: "KuGo"
            case .lrclib: "LRCLIB"
            }
        }

        /// Short description shown beneath the provider name in settings.
        var detail: String {
            switch self {
            case .betterLyrics: String(localized: "Apple Music TTML · word-synced")
            case .paxsenix: String(localized: "Apple Music · word-synced")
            case .kugou: String(localized: "KuGou · line-synced")
            case .lrclib: String(localized: "Community · line-synced")
            }
        }
    }

    /// The default priority order, highest first.
    static let defaultLyricsProviderOrder: [LyricsProviderID] = [.betterLyrics, .paxsenix, .kugou, .lrclib]

    // MARK: - Settings Properties

    /// Whether to show system notifications when the track changes.
    var showNowPlayingNotifications: Bool {
        didSet {
            UserDefaults.standard.set(self.showNowPlayingNotifications, forKey: Keys.showNowPlayingNotifications)
        }
    }

    /// The default page to show when the app launches.
    var defaultLaunchPage: LaunchPage {
        didSet {
            UserDefaults.standard.set(self.defaultLaunchPage.rawValue, forKey: Keys.defaultLaunchPage)
        }
    }

    /// Whether haptic feedback is enabled.
    var hapticFeedbackEnabled: Bool {
        didSet {
            UserDefaults.standard.set(self.hapticFeedbackEnabled, forKey: Keys.hapticFeedbackEnabled)
        }
    }

    /// Whether to remember shuffle/repeat settings across app restarts.
    var rememberPlaybackSettings: Bool {
        didSet {
            UserDefaults.standard.set(self.rememberPlaybackSettings, forKey: Keys.rememberPlaybackSettings)
            // Clear stale values when setting is disabled to prevent unexpected restoration
            if !self.rememberPlaybackSettings {
                UserDefaults.standard.removeObject(forKey: "playerShuffleEnabled")
                UserDefaults.standard.removeObject(forKey: "playerRepeatMode")
            }
        }
    }

    /// Which buttons to show in the Now Playing widget: skip forward/backward or next/previous track.
    var mediaControlStyle: MediaControlStyle {
        didSet {
            UserDefaults.standard.set(self.mediaControlStyle.rawValue, forKey: Keys.mediaControlStyle)
        }
    }

    /// Per-service enabled flags stored as a dictionary.
    private var enabledServices: [String: Bool] {
        didSet {
            UserDefaults.standard.set(self.enabledServices, forKey: Keys.enabledServices)
        }
    }

    /// Whether a specific scrobbling service is enabled by name.
    func isServiceEnabled(_ serviceName: String) -> Bool {
        self.enabledServices[serviceName] ?? false
    }

    /// Whether the user has an explicit persisted preference for a service.
    /// Distinguishes between "never configured" and "explicitly disabled".
    func hasExplicitServicePreference(_ serviceName: String) -> Bool {
        self.enabledServices[serviceName] != nil
    }

    /// Sets the enabled state for a specific scrobbling service by name.
    func setServiceEnabled(_ serviceName: String, _ enabled: Bool) {
        self.enabledServices[serviceName] = enabled
    }

    /// Whether Last.fm scrobbling is enabled (backward-compatible convenience).
    var lastFMEnabled: Bool {
        get { self.isServiceEnabled("Last.fm") }
        set { self.setServiceEnabled("Last.fm", newValue) }
    }

    /// Percentage of track duration required before scrobbling (0.0–1.0).
    var scrobblePercentThreshold: Double {
        didSet {
            UserDefaults.standard.set(self.scrobblePercentThreshold, forKey: Keys.scrobblePercentThreshold)
        }
    }

    /// Minimum seconds of play time before scrobbling (overrides percentage for long tracks).
    var scrobbleMinSeconds: TimeInterval {
        didSet {
            UserDefaults.standard.set(self.scrobbleMinSeconds, forKey: Keys.scrobbleMinSeconds)
        }
    }

    /// The last page the user was on (for "Last Used" option).
    var lastUsedPage: LaunchPage = .home

    /// Priority order of the lyrics providers, highest first.
    private(set) var lyricsProviderOrder: [LyricsProviderID] {
        didSet {
            UserDefaults.standard.set(self.lyricsProviderOrder.map(\.rawValue), forKey: Keys.lyricsProviderOrder)
        }
    }

    /// Providers the user switched off. Stored separately from the order so
    /// re-enabling a provider restores it to its previous priority.
    private(set) var disabledLyricsProviders: Set<LyricsProviderID> {
        didSet {
            UserDefaults.standard.set(self.disabledLyricsProviders.map(\.rawValue), forKey: Keys.lyricsDisabledProviders)
        }
    }

    /// Enabled providers in priority order — exactly what the lyrics service searches.
    var enabledLyricsProviders: [LyricsProviderID] {
        Self.enabledLyricsProviders(
            order: self.lyricsProviderOrder,
            disabled: self.disabledLyricsProviders
        )
    }

    nonisolated static func enabledLyricsProviders(
        order: [LyricsProviderID],
        disabled: Set<LyricsProviderID>
    ) -> [LyricsProviderID] {
        order.filter { !disabled.contains($0) }
    }

    func isLyricsProviderEnabled(_ id: LyricsProviderID) -> Bool {
        !self.disabledLyricsProviders.contains(id)
    }

    func setLyricsProvider(_ id: LyricsProviderID, enabled: Bool) {
        if enabled {
            self.disabledLyricsProviders.remove(id)
        } else {
            self.disabledLyricsProviders.insert(id)
        }
    }

    /// Reorders the provider list, e.g. from a drag operation. Mirrors SwiftUI's
    /// `move(fromOffsets:toOffset:)` semantics without importing SwiftUI here.
    func moveLyricsProviders(fromOffsets source: IndexSet, toOffset destination: Int) {
        self.lyricsProviderOrder = Self.reorderedLyricsProviders(
            self.lyricsProviderOrder,
            from: source,
            to: destination
        )
    }

    nonisolated static func reorderedLyricsProviders(
        _ order: [LyricsProviderID],
        from source: IndexSet,
        to destination: Int
    ) -> [LyricsProviderID] {
        let moving = source.compactMap { order.indices.contains($0) ? order[$0] : nil }
        var remaining = order
        for index in source.sorted(by: >) where order.indices.contains(index) {
            remaining.remove(at: index)
        }
        let insertIndex = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: max(0, min(insertIndex, remaining.count)))
        return remaining
    }

    /// Moves a single provider one slot up (`offset` = -1) or down (`offset` = 1).
    func moveLyricsProvider(_ id: LyricsProviderID, by offset: Int) {
        guard let index = self.lyricsProviderOrder.firstIndex(of: id) else { return }
        let target = index + offset
        guard self.lyricsProviderOrder.indices.contains(target) else { return }
        var order = self.lyricsProviderOrder
        order.swapAt(index, target)
        self.lyricsProviderOrder = order
    }

    /// Drops `id` onto `target`, landing at `target`'s position and shifting the
    /// providers in between. Used by drag-and-drop reordering.
    func moveLyricsProvider(_ id: LyricsProviderID, to target: LyricsProviderID) {
        self.lyricsProviderOrder = Self.reorderedLyricsProviders(
            self.lyricsProviderOrder,
            moving: id,
            onto: target
        )
    }

    nonisolated static func reorderedLyricsProviders(
        _ order: [LyricsProviderID],
        moving id: LyricsProviderID,
        onto target: LyricsProviderID
    ) -> [LyricsProviderID] {
        guard id != target,
              let from = order.firstIndex(of: id),
              let to = order.firstIndex(of: target)
        else { return order }
        let destination = from < to ? to + 1 : to
        return Self.reorderedLyricsProviders(order, from: IndexSet(integer: from), to: destination)
    }

    /// Whether synced lyrics are preferred.
    var syncedLyricsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(self.syncedLyricsEnabled, forKey: Keys.syncedLyricsEnabled)
        }
    }

    /// Whether conservative ad blocking hooks are enabled.
    var safeAdBlockingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(self.safeAdBlockingEnabled, forKey: Keys.safeAdBlockingEnabled)
        }
    }

    /// Whether animated album canvases are shown in the fullscreen now-playing view.
    var animatedCanvasEnabled: Bool {
        didSet {
            UserDefaults.standard.set(self.animatedCanvasEnabled, forKey: Keys.animatedCanvasEnabled)
        }
    }

    // MARK: - Initialization

    private init() {
        // Load persisted settings or use defaults
        self.showNowPlayingNotifications = UserDefaults.standard.object(forKey: Keys.showNowPlayingNotifications) as? Bool ?? true
        self.hapticFeedbackEnabled = UserDefaults.standard.object(forKey: Keys.hapticFeedbackEnabled) as? Bool ?? true
        self.rememberPlaybackSettings = UserDefaults.standard.object(forKey: Keys.rememberPlaybackSettings) as? Bool ?? false

        // Load per-service enabled flags, migrating from legacy lastFMEnabled if needed
        if let stored = UserDefaults.standard.dictionary(forKey: Keys.enabledServices) as? [String: Bool] {
            self.enabledServices = stored
        } else if let legacyEnabled = UserDefaults.standard.object(forKey: Keys.lastFMEnabled) as? Bool {
            // Migrate from single-service flag to dictionary
            self.enabledServices = ["Last.fm": legacyEnabled]
        } else {
            self.enabledServices = [:]
        }
        self.scrobblePercentThreshold = UserDefaults.standard.object(forKey: Keys.scrobblePercentThreshold) as? Double ?? 0.5
        self.scrobbleMinSeconds = UserDefaults.standard.object(forKey: Keys.scrobbleMinSeconds) as? Double ?? 240
        self.syncedLyricsEnabled = UserDefaults.standard.object(forKey: Keys.syncedLyricsEnabled) as? Bool ?? true
        if let storedOrder = UserDefaults.standard.stringArray(forKey: Keys.lyricsProviderOrder) {
            let storedIDs = storedOrder.compactMap(LyricsProviderID.init(rawValue:))
            // Append providers added since the order was saved so new sources
            // become available without a migration.
            let missing = LyricsProviderID.allCases.filter { !storedIDs.contains($0) }
            self.lyricsProviderOrder = storedIDs + missing
        } else {
            self.lyricsProviderOrder = Self.defaultLyricsProviderOrder
        }

        if let storedDisabled = UserDefaults.standard.stringArray(forKey: Keys.lyricsDisabledProviders) {
            self.disabledLyricsProviders = Set(storedDisabled.compactMap(LyricsProviderID.init(rawValue:)))
        } else {
            // Migrate the legacy single-choice preset into the per-provider model.
            self.disabledLyricsProviders = Self.disabledProvidersForLegacyChoice(
                UserDefaults.standard.string(forKey: Keys.lyricsProvider)
            )
        }
        self.safeAdBlockingEnabled = UserDefaults.standard.object(forKey: Keys.safeAdBlockingEnabled) as? Bool ?? true
        self.animatedCanvasEnabled = UserDefaults.standard.object(forKey: Keys.animatedCanvasEnabled) as? Bool ?? true

        if let rawValue = UserDefaults.standard.string(forKey: Keys.mediaControlStyle),
           let style = MediaControlStyle(rawValue: rawValue)
        {
            self.mediaControlStyle = style
        } else {
            self.mediaControlStyle = .nextPreviousTrack
        }

        if let rawValue = UserDefaults.standard.string(forKey: Keys.defaultLaunchPage),
           let page = LaunchPage(rawValue: rawValue)
        {
            self.defaultLaunchPage = page
        } else {
            self.defaultLaunchPage = .home
        }

        // Persist migration from legacy lastFMEnabled key (must run after all properties initialized)
        if UserDefaults.standard.object(forKey: Keys.enabledServices) == nil,
           UserDefaults.standard.object(forKey: Keys.lastFMEnabled) != nil
        {
            UserDefaults.standard.set(self.enabledServices, forKey: Keys.enabledServices)
            UserDefaults.standard.removeObject(forKey: Keys.lastFMEnabled)
        }
    }

    // MARK: - Migration

    /// Maps the legacy single-choice preset to the disabled-provider set of the
    /// new per-provider model.
    nonisolated static func disabledProvidersForLegacyChoice(_ rawValue: String?) -> Set<LyricsProviderID> {
        switch rawValue {
        case "betterLyrics": [.paxsenix, .kugou, .lrclib]
        case "kugouAndLRCLib": [.betterLyrics, .paxsenix]
        case "lrclib": [.betterLyrics, .paxsenix, .kugou]
        default: [] // "paxsenixAndLRCLib" (or never configured): everything enabled
        }
    }

    // MARK: - Computed Properties

    /// Returns the page to navigate to on launch based on settings.
    var launchPage: LaunchPage {
        switch self.defaultLaunchPage {
        case .lastUsed:
            self.lastUsedPage
        default:
            self.defaultLaunchPage
        }
    }

    /// Returns the NavigationItem to use on app launch.
    var launchNavigationItem: NavigationItem {
        self.launchPage.navigationItem
    }
}
