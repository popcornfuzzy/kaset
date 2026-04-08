import Foundation

// MARK: - LRCLibModel

struct LRCLibModel: Decodable {
    let id: Int
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: TimeInterval?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?
}

// MARK: - LRCLibProvider

final class LRCLibProvider: LyricsProvider {
    let name = "LRCLib"
    private let userAgent = "Kaset/1.0"

    func search(info: LyricsSearchInfo) async -> LyricResult {
        let normalizedArtist = LyricsArtistNormalizer.normalizeForSearch(info.artist)
        let preferredArtistQuery = normalizedArtist.isEmpty ? info.artist : normalizedArtist
        var artistQueries = [preferredArtistQuery]
        if preferredArtistQuery != info.artist {
            artistQueries.append(info.artist)
        }

        let normalizedTitle = LyricsArtistNormalizer.normalizeTitleForSearch(info.title)
        let preferredTitleQuery = normalizedTitle.isEmpty ? info.title : normalizedTitle
        var titleQueries = [preferredTitleQuery]
        if preferredTitleQuery != info.title {
            titleQueries.append(info.title)
        }

        do {
            var validParams: [LRCLibModel] = []

            for titleQuery in titleQueries {
                for artistQuery in artistQueries {
                    let results = try await Self.requestSearchResults(
                        title: titleQuery,
                        artist: artistQuery,
                        userAgent: self.userAgent
                    )

                    let filtered = results.filter {
                        ($0.syncedLyrics != nil || $0.plainLyrics != nil) &&
                            ($0.instrumental == false || $0.instrumental == nil)
                    }

                    if !filtered.isEmpty {
                        validParams = filtered
                        break
                    }
                }

                if !validParams.isEmpty {
                    break
                }
            }

            guard !validParams.isEmpty else { return .unavailable }

            let bestMatch = Self.selectBestMatch(from: validParams, info: info)

            if let synced = bestMatch.syncedLyrics, let parsed = LRCParser.parse(synced) {
                let withSource = SyncedLyrics(lines: parsed.lines, source: self.name)
                return .synced(withSource)
            } else if let plain = bestMatch.plainLyrics {
                return .plain(Lyrics(text: plain, source: "Source: \(self.name)"))
            }

            return .unavailable
        } catch {
            return .unavailable
        }
    }

    private static func requestSearchResults(title: String, artist: String, userAgent: String) async throws -> [LRCLibModel] {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]

        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }

        return try JSONDecoder().decode([LRCLibModel].self, from: data)
    }

    static func selectBestMatch(from candidates: [LRCLibModel], info: LyricsSearchInfo) -> LRCLibModel {
        guard let first = candidates.first else {
            preconditionFailure("selectBestMatch requires at least one candidate")
        }

        let queryArtist = LyricsArtistNormalizer.normalizeForSearch(info.artist)
        let queryArtistComponents = LyricsArtistNormalizer.artistComponents(info.artist)
        let queryTitle = LyricsArtistNormalizer.normalizeTitleForSearch(info.title)

        var bestCandidate = first
        var bestScore = Self.matchScore(
            candidate: first,
            queryArtist: queryArtist,
            queryArtistComponents: queryArtistComponents,
            queryTitle: queryTitle,
            duration: info.duration
        )

        for candidate in candidates.dropFirst() {
            let score = Self.matchScore(
                candidate: candidate,
                queryArtist: queryArtist,
                queryArtistComponents: queryArtistComponents,
                queryTitle: queryTitle,
                duration: info.duration
            )

            if score > bestScore {
                bestCandidate = candidate
                bestScore = score
            }
        }

        return bestCandidate
    }

    private static func matchScore(
        candidate: LRCLibModel,
        queryArtist: String,
        queryArtistComponents: Set<String>,
        queryTitle: String,
        duration: TimeInterval?
    ) -> Int {
        var score = 0

        let candidateArtist = LyricsArtistNormalizer.normalizeForSearch(candidate.artistName ?? "")
        let candidateArtistComponents = LyricsArtistNormalizer.artistComponents(candidate.artistName ?? "")
        let candidateTitle = LyricsArtistNormalizer.normalizeTitleForSearch(candidate.trackName ?? "")

        if !queryArtist.isEmpty, !candidateArtist.isEmpty {
            if candidateArtist == queryArtist {
                score += 2_000
            }

            if candidateArtist.contains(queryArtist) || queryArtist.contains(candidateArtist) {
                score += 800
            }

            let overlap = queryArtistComponents.intersection(candidateArtistComponents).count
            score += overlap * 300
        }

        if !queryTitle.isEmpty, !candidateTitle.isEmpty {
            if candidateTitle == queryTitle {
                score += 1_600
            }

            if candidateTitle.contains(queryTitle) || queryTitle.contains(candidateTitle) {
                score += 600
            }
        }

        if candidate.syncedLyrics != nil {
            score += 50
        }

        if let duration {
            let durationDiff = abs((candidate.duration ?? 0) - duration)
            let durationPoints = max(0, 100 - Int(durationDiff))
            score += durationPoints
        }

        return score
    }
}
