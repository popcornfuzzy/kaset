import Foundation

// MARK: - CanvasSearchInfo

/// Information needed to look up an animated canvas for the current track.
struct CanvasSearchInfo: Sendable, Equatable {
    let title: String
    let artist: String
    let album: String?
    let videoId: String
}

// MARK: - CanvasArtwork

/// An animated canvas video resolved for an album/track.
struct CanvasArtwork: Sendable, Codable, Hashable {
    let name: String?
    let artist: String?
    let videoURL: URL
    let source: String
    let albumName: String?

    /// HLS streams must be played directly from their remote URL. Direct files
    /// (Tidal MP4s) can be downloaded once and replayed from the canvas cache.
    var isHLS: Bool {
        self.videoURL.lastPathComponent.lowercased().contains(".m3u8")
    }
}

// MARK: - CanvasProvider

/// Protocol all canvas providers conform to.
protocol CanvasProvider: Sendable {
    var name: String { get }

    /// Resolves an animated canvas for the given track, or nil when none exists.
    func fetchCanvas(for info: CanvasSearchInfo) async -> CanvasArtwork?
}

// MARK: - CanvasMatching

/// Shared matching helpers used by canvas providers (ported from the Android
/// reference implementation's normalization logic).
enum CanvasMatching {
    /// Normalizes a string for fuzzy comparison: diacritics folded away, lowercased,
    /// punctuation turned into a separator, whitespace collapsed, and trimmed.
    ///
    /// Diacritic folding matters because Tidal and YouTube Music disagree on accents
    /// (Tidal writes "ROSALÍA", YouTube Music may write "Rosalia"; the same split shows
    /// up on "Beyoncé"/"Beyonce" and "Motörhead"/"Motorhead") and an accent mismatch
    /// silently rejected an otherwise correct result.
    ///
    /// Punctuation becomes a *space* rather than being deleted so hyphenated titles
    /// still match their unhyphenated spelling: deleting the hyphen makes
    /// "Anti-Hero" normalize to `antihero`, which does not equal "Anti Hero"'s
    /// `anti hero`. Both catalogs spell such titles inconsistently.
    ///
    /// Unlike the Android reference implementation this keeps non-Latin letters and
    /// digits (`\p{L}`/`\p{N}`) instead of restricting to `[a-z0-9]`, which would
    /// collapse every Cyrillic, Greek, Arabic, or CJK title to the empty string —
    /// and an empty needle matches nothing meaningful.
    static func normalizeForComparison(_ string: String) -> String {
        // NFD then dropping the Combining Diacritical Marks block mirrors the
        // reference implementation's `Normalizer` pass without depending on the
        // current locale (unlike `folding(options:)`, which is locale-sensitive).
        let decomposed = string.decomposedStringWithCanonicalMapping
        var folded = String.UnicodeScalarView()
        for scalar in decomposed.unicodeScalars where !(0x0300 ... 0x036F).contains(scalar.value) {
            folded.append(scalar)
        }
        return String(folded)
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits an artist string into individual normalized artist components.
    /// Handles separators like ",", "&", "x", "×", "feat.", "ft.", "featuring",
    /// and "with" (case-insensitive).
    static func artistComponents(_ artist: String) -> [String] {
        let replacements: [(String, String)] = [
            (#"\s*,\s*"#, "|"),
            (#"\s*&\s*"#, "|"),
            (#"\s+×\s+"#, "|"),
            (#"\s+x\s+"#, "|"),
            (#"\s+feat\.?\s+"#, "|"),
            (#"\s+ft\.?\s+"#, "|"),
            (#"\s+featuring\s+"#, "|"),
            (#"\s+with\s+"#, "|"),
        ]

        var separated = artist
        for (pattern, replacement) in replacements {
            separated = separated.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return separated
            .split(separator: "|")
            .map { Self.normalizeForComparison(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Case- and diacritic-insensitive containment check.
    static func containsIgnoringCase(_ haystack: String, _ needle: String) -> Bool {
        guard !haystack.isEmpty, !needle.isEmpty else { return false }
        return haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Case- and diacritic-insensitive equality check.
    static func equalsIgnoringCase(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
