import Foundation

enum LyricsArtistNormalizer {
    static func normalizeForSearch(_ artist: String) -> String {
        var normalized = artist
            .folding(options: [.diacriticInsensitive], locale: .current)
            .lowercased()

        // Remove explicit year suffixes often embedded in artist labels.
        normalized = normalized.replacingOccurrences(
            of: #"\s*\(\d{4}\)\s*"#,
            with: " ",
            options: .regularExpression
        )

        // Normalize conjunctions commonly used for multiple artists across locales.
        normalized = normalized.replacingOccurrences(
            of: #"\b(?:und|et|y)\b"#,
            with: " and ",
            options: [.regularExpression, .caseInsensitive]
        )
        normalized = normalized.replacingOccurrences(of: " & ", with: " and ")

        // Harmonize separators so matching behaves consistently.
        normalized = normalized.replacingOccurrences(
            of: #"\s*[,;/|]+\s*"#,
            with: ", ",
            options: .regularExpression
        )

        normalized = normalized.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        normalized = normalized.replacingOccurrences(
            of: #"\s*,\s*"#,
            with: ", ",
            options: .regularExpression
        )

        let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        return normalized.trimmingCharacters(in: trimSet)
    }

    static func artistComponents(_ artist: String) -> Set<String> {
        let normalized = Self.normalizeForSearch(artist)
        guard !normalized.isEmpty else { return [] }

        let normalizedWithDelimiters = normalized
            .replacingOccurrences(of: " and ", with: ", ")
            .replacingOccurrences(of: #"\s*,\s*"#, with: ",", options: .regularExpression)

        return Set(
            normalizedWithDelimiters
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    static func normalizeTitleForSearch(_ title: String) -> String {
        var normalized = title
            .folding(options: [.diacriticInsensitive], locale: .current)
            .lowercased()

        normalized = normalized.replacingOccurrences(
            of: #"\s*\((?:official\s+)?(?:lyric\s+)?video\)\s*"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        normalized = normalized.replacingOccurrences(
            of: #"\s*\(official\s+visualizer\)\s*"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )

        normalized = normalized.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
