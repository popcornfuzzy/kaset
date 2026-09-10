import Foundation

// MARK: - LyricsSearchInfo

/// Information needed to search for lyrics.
struct LyricsSearchInfo: Sendable {
    let title: String
    let artist: String
    let album: String?
    let duration: TimeInterval? // seconds
    let videoId: String
}

// MARK: - LyricsCapability

/// Fidelity of a lyrics result, from lowest to highest. Providers declare the
/// best they can produce so the search knows whether a higher-quality result
/// might still arrive while a lower-quality one is already on screen.
///
/// - `plain`: Untimed plain-text lyrics.
/// - `line`: Line-synced lyrics (timestamps per line, no word timings).
/// - `word`: Word-synced lyrics (per-word timings for karaoke display).
enum LyricsCapability: Int, Comparable, Sendable {
    case plain = 0
    case line = 1
    case word = 2

    static func < (lhs: LyricsCapability, rhs: LyricsCapability) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - LyricsProvider

/// Protocol all lyrics providers conform to.
protocol LyricsProvider: Sendable {
    var name: String { get }

    /// Highest fidelity this provider is capable of returning. Used to decide
    /// whether a better result may still arrive after the first one is shown.
    var capability: LyricsCapability { get }

    func search(info: LyricsSearchInfo) async -> LyricResult
}

// MARK: - Result capability

extension LyricResult {
    /// Fidelity derived from the actual payload — a provider that "can" return
    /// word timings still produces a line-tier result when a song only has an
    /// LRC fallback.
    var capability: LyricsCapability {
        switch self {
        case let .synced(lyrics):
            lyrics.hasWordTiming ? .word : .line
        case .plain:
            .plain
        case .unavailable:
            .plain
        }
    }

    /// Numeric rank used for replacement decisions; `.unavailable` sorts below
    /// every real result so the first valid arrival is always displayed.
    var capabilityRank: Int {
        switch self {
        case .unavailable: -1
        case let .synced(lyrics): lyrics.hasWordTiming ? 2 : 1
        case .plain: 0
        }
    }
}
