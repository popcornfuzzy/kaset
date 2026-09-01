import Foundation

/// Fetches lyrics through the unofficial endpoint used by Musixmatch's desktop client.
///
/// This endpoint is not the licensed Musixmatch Pro API and may change without notice.
final class MusixmatchProvider: LyricsProvider {
    let name = "Musixmatch"

    private let baseURL = URL(string: "https://apic-desktop.musixmatch.com/ws/1.1/")
    private let session: URLSession
    private let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(info: LyricsSearchInfo) async -> LyricResult {
        do {
            let token = try await self.fetchToken()
            guard            let track = try await self.findTrack(info: info, token: token) else {
                return .unavailable
            }

            if track.hasRichSync {
                if let rich = try await self.fetchRichSync(trackID: track.id, token: token),
                   let lyrics = Self.parseRichSync(rich, source: self.name)
                {
                    return .synced(lyrics)
                }
            }

            if track.hasSubtitles,
               let lrc = try await self.fetchSubtitle(trackID: track.id, token: token),
               let lyrics = LRCParser.parse(lrc)
            {
                return .synced(SyncedLyrics(lines: lyrics.lines, source: self.name))
            }

            return .unavailable
        } catch is CancellationError {
            return .unavailable
        } catch {
            DiagnosticsLogger.api.warning("Musixmatch lyrics request failed: \(error.localizedDescription)")
            return .unavailable
        }
    }

    private struct APIResponse: Decodable {
        let message: Message

        struct Message: Decodable {
            let header: Header
            let body: Body?
        }

        struct Header: Decodable {
            let statusCode: Int

            enum CodingKeys: String, CodingKey { case statusCode = "status_code" }
        }

        struct Body: Decodable {
            let userToken: String?
            let track: Track?
            let richSync: RichSyncContainer?
            let subtitle: SubtitleContainer?

            enum CodingKeys: String, CodingKey {
                case userToken = "user_token"
                case track, richSync = "richsync", subtitle
            }
        }

        struct Track: Decodable {
            let trackID: Int
            let trackName: String?
            let artistName: String?
            let hasRichSync: Int?
            let hasSubtitles: Int?

            enum CodingKeys: String, CodingKey {
                case trackID = "track_id"
                case trackName = "track_name"
                case artistName = "artist_name"
                case hasRichSync = "has_richsync"
                case hasSubtitles = "has_subtitles"
            }

            var id: Int { self.trackID }
            var hasRichSyncValue: Bool { self.hasRichSync == 1 }
            var hasSubtitlesValue: Bool { self.hasSubtitles == 1 }
        }

        struct RichSyncContainer: Decodable {
            let body: String?

            enum CodingKeys: String, CodingKey { case body = "richsync_body" }
        }

        struct SubtitleContainer: Decodable {
            let body: String?

            enum CodingKeys: String, CodingKey { case body = "subtitle_body" }
        }
    }

    private struct TrackMatch {
        let id: Int
        let hasRichSync: Bool
        let hasSubtitles: Bool
    }

    private struct RichSyncLine: Decodable {
        let start: Double
        let end: Double
        let words: [Word]

        enum CodingKeys: String, CodingKey {
            case start = "ts"
            case end = "te"
            case words = "l"
        }

        struct Word: Decodable {
            let text: String
            let offset: Double

            enum CodingKeys: String, CodingKey {
                case text = "c"
                case offset = "o"
            }
        }
    }

    private func makeRequest(action: String, query: [URLQueryItem]) async throws -> APIResponse {
        guard let baseURL else { throw URLError(.badURL) }
        var components = URLComponents(url: baseURL.appendingPathComponent(action), resolvingAgainstBaseURL: false)
        components?.queryItems = query + [URLQueryItem(name: "app_id", value: "web-desktop-app-v1.0")]
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://www.musixmatch.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.musixmatch.com/", forHTTPHeaderField: "Referer")

        let (data, response) = try await self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode)
        else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(APIResponse.self, from: data)
    }

    private func fetchToken() async throws -> String {
        let response = try await self.makeRequest(
            action: "token.get",
            query: [URLQueryItem(name: "user_language", value: "en")]
        )
        guard response.message.header.statusCode == 200,
              let token = response.message.body?.userToken,
              !token.isEmpty
        else {
            throw URLError(.userAuthenticationRequired)
        }
        return token
    }

    private func findTrack(info: LyricsSearchInfo, token: String) async throws -> TrackMatch? {
        let normalizedTitle = LyricsArtistNormalizer.normalizeTitleForSearch(info.title)
        let normalizedArtist = LyricsArtistNormalizer.normalizeForSearch(info.artist)
        var query = [
            URLQueryItem(name: "q_track", value: normalizedTitle.isEmpty ? info.title : normalizedTitle),
            URLQueryItem(name: "q_artist", value: normalizedArtist.isEmpty ? info.artist : normalizedArtist),
            URLQueryItem(name: "page_size", value: "1"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "usertoken", value: token),
        ]
        if let album = info.album, !album.isEmpty {
            query.append(URLQueryItem(name: "album", value: album))
        }

        let response = try await self.makeRequest(action: "matcher.track.get", query: query)
        guard response.message.header.statusCode == 200,
              let track = response.message.body?.track
        else {
            return nil
        }
        guard Self.isAcceptableMatch(track: track, info: info) else { return nil }
        return TrackMatch(id: track.id, hasRichSync: track.hasRichSyncValue, hasSubtitles: track.hasSubtitlesValue)
    }

    private func fetchRichSync(trackID: Int, token: String) async throws -> String? {
        let response = try await self.makeRequest(
            action: "track.richsync.get",
            query: [
                URLQueryItem(name: "track_id", value: String(trackID)),
                URLQueryItem(name: "usertoken", value: token),
            ]
        )
        guard response.message.header.statusCode == 200 else { return nil }
        return response.message.body?.richSync?.body
    }

    private func fetchSubtitle(trackID: Int, token: String) async throws -> String? {
        let response = try await self.makeRequest(
            action: "track.subtitle.get",
            query: [
                URLQueryItem(name: "track_id", value: String(trackID)),
                URLQueryItem(name: "subtitle_format", value: "lrc"),
                URLQueryItem(name: "usertoken", value: token),
            ]
        )
        guard response.message.header.statusCode == 200 else { return nil }
        return response.message.body?.subtitle?.body
    }

    private static func isAcceptableMatch(track: APIResponse.Track, info: LyricsSearchInfo) -> Bool {
        let requestedTitle = LyricsArtistNormalizer.normalizeTitleForSearch(info.title)
        let requestedArtist = LyricsArtistNormalizer.normalizeForSearch(info.artist)
        let returnedTitle = LyricsArtistNormalizer.normalizeTitleForSearch(track.trackName ?? "")
        let returnedArtist = LyricsArtistNormalizer.normalizeForSearch(track.artistName ?? "")
        let titleMatches = !requestedTitle.isEmpty && !returnedTitle.isEmpty &&
            (requestedTitle == returnedTitle || requestedTitle.contains(returnedTitle) || returnedTitle.contains(requestedTitle))
        let artistMatches = !requestedArtist.isEmpty && !returnedArtist.isEmpty &&
            (requestedArtist == returnedArtist || requestedArtist.contains(returnedArtist) || returnedArtist.contains(requestedArtist))
        return titleMatches && artistMatches
    }

    static func parseRichSync(_ raw: String, source: String = "Musixmatch") -> SyncedLyrics? {
        guard let data = raw.data(using: .utf8),
              let richLines = try? JSONDecoder().decode([RichSyncLine].self, from: data),
              !richLines.isEmpty
        else { return nil }

        let sorted = richLines.sorted { $0.start < $1.start }
        let lines = sorted.enumerated().map { index, richLine in
            let words = Self.coalesceWordFragments(richLine.words, lineStart: richLine.start)
            let text = words.map(\.word).joined()
            let nextStart = sorted.indices.contains(index + 1) ? sorted[index + 1].start : richLine.end
            return SyncedLyricLine(
                timeInMs: max(0, Int(richLine.start * 1000)),
                duration: max(1, Int((nextStart - richLine.start) * 1000)),
                text: text,
                words: words.isEmpty ? nil : words
            )
        }

        return SyncedLyrics(lines: lines, source: source)
    }

    /// Musixmatch rich-sync often returns character chunks, not semantic words.
    /// Join adjacent chunks until whitespace boundaries while retaining the first
    /// character's timestamp for a stable karaoke highlight.
    private static func coalesceWordFragments(_ fragments: [RichSyncLine.Word], lineStart: Double) -> [TimedWord] {
        var result: [TimedWord] = []
        var pending = ""
        var pendingTime = 0

        for fragment in fragments {
            let text = fragment.text
            if pending.isEmpty {
                pendingTime = max(0, Int((lineStart + fragment.offset) * 1000))
            }
            pending += text

            let endsWithWhitespace = text.last?.isWhitespace == true
            if endsWithWhitespace {
                result.append(TimedWord(timeInMs: pendingTime, word: pending))
                pending = ""
            }
        }

        if !pending.isEmpty {
            result.append(TimedWord(timeInMs: pendingTime, word: pending))
        }
        return result
    }
}
