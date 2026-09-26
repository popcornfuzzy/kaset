import Foundation

/// Fetches lyrics through the Paxsenix lyrics service.
///
/// Flow: obtain an Apple Music web token, search the Apple Music catalog, then
/// fetch lyrics for the best-matching track from `lyrics.paxsenix.org`.
/// Lyrics arrive as word-synced ELRC/TTML, line-synced LRC, or plain text.
final class PaxsenixProvider: LyricsProvider {
    let name = "Paxsenix"
    let capability: LyricsCapability = .word

    private static let lyricsBaseURL = URL(string: "https://lyrics.paxsenix.org")!
    private static let appleMusicSearchURL = "https://amp-api.music.apple.com/v1/catalog/us/search"

    private let session: URLSession
    private let appleBrowserUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:95.0) Gecko/20100101 Firefox/95.0"
    private let tokenStore = PaxsenixTokenStore()

    private static var appUserAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Kaset/\(version)"
    }

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Public

    func search(info: LyricsSearchInfo) async -> LyricResult {
        do {
            return try await self.fetchLyrics(info: info)
        } catch is CancellationError {
            return .unavailable
        } catch {
            DiagnosticsLogger.api.warning("Paxsenix lyrics request failed: \(error.localizedDescription)")
            return .unavailable
        }
    }

    // MARK: - Flow

    private func fetchLyrics(info: LyricsSearchInfo) async throws -> LyricResult {
        let cleanedTitle = Self.cleanTitle(info.title)
        let cleanedArtist = Self.cleanArtist(info.artist)

        var queries = ["\(cleanedTitle) \(cleanedArtist)", cleanedTitle]
        if let album = info.album, !album.isEmpty {
            queries.append("\(cleanedTitle) \(cleanedArtist) \(album)")
        }

        var scoredTracks: [PaxsenixTrack] = []
        for query in queries where scoredTracks.isEmpty {
            let results = try await self.search(query: query)
            scoredTracks = Self.scoreAndFilter(results, title: info.title, artist: info.artist, duration: info.duration)
        }

        guard !scoredTracks.isEmpty else { return .unavailable }

        var bestResult: LyricResult = .unavailable
        var bestRank = -1
        for track in scoredTracks.prefix(10) {
            guard let response = try await self.fetchLyricsResponse(trackID: track.id) else { continue }
            let result = Self.parse(response, source: self.name)
            guard result.isAvailable else { continue }
            let rank = result.capabilityRank
            if rank > bestRank {
                bestRank = rank
                bestResult = result
            }
            // Word-synced is the best fidelity available — stop early.
            if rank >= LyricsCapability.word.rawValue { break }
        }
        return bestResult
    }

    // MARK: - Apple Music search

    private func search(query: String) async throws -> [PaxsenixTrack] {
        let token = try await self.appleMusicToken()
        do {
            return try await self.searchWithToken(token, query: query)
        } catch is AppleMusicAuthError {
            await self.tokenStore.clearToken()
            let freshToken = try await self.appleMusicToken()
            return try await self.searchWithToken(freshToken, query: query)
        }
    }

    private func searchWithToken(_ token: String, query: String) async throws -> [PaxsenixTrack] {
        guard var components = URLComponents(string: Self.appleMusicSearchURL) else { throw URLError(.badURL) }
        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "l", value: "en-US"),
            URLQueryItem(name: "platform", value: "web"),
            URLQueryItem(name: "format[resources]", value: "map"),
            URLQueryItem(name: "include[songs]", value: "artists"),
            URLQueryItem(name: "extend", value: "artistUrl"),
        ]
        guard let url = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.apple.com/", forHTTPHeaderField: "Referer")
        request.setValue(self.appleBrowserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        request.setValue("true", forHTTPHeaderField: "x-apple-renewal")

        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 || http.statusCode == 402 { throw AppleMusicAuthError() }
        guard (200 ..< 300).contains(http.statusCode) else { throw URLError(.badServerResponse) }

        let decoded = try JSONDecoder().decode(AppleSearchResponse.self, from: data)
        guard let refs = decoded.results?.songs?.data else { return [] }
        return refs.compactMap { ref -> PaxsenixTrack? in
            let attributes = decoded.resources?.songs?[ref.id]?.attributes ?? ref.attributes
            guard let attributes, let name = attributes.name else { return nil }
            return PaxsenixTrack(
                id: ref.id,
                name: name,
                artist: attributes.artistName ?? "",
                duration: attributes.durationInMillis.map { $0 / 1000 }
            )
        }
    }

    // MARK: - Lyrics fetch

    private func fetchLyricsResponse(trackID: String) async throws -> PaxsenixLyricsResponse? {
        var components = URLComponents(url: Self.lyricsBaseURL.appendingPathComponent("apple-music/lyrics"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: trackID)]
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.setValue(Self.appUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(PaxsenixLyricsResponse.self, from: data)
    }

    // MARK: - Apple Music token

    private func appleMusicToken() async throws -> String {
        if let cached = await self.tokenStore.cachedToken() { return cached }
        let token = try await Self.fetchAppleMusicToken(session: self.session, browserUserAgent: self.appleBrowserUserAgent)
        await self.tokenStore.setToken(token)
        return token
    }

    private static func fetchAppleMusicToken(session: URLSession, browserUserAgent: String) async throws -> String {
        var pageRequest = URLRequest(url: URL(string: "https://beta.music.apple.com")!)
        pageRequest.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        let (pageData, pageResponse) = try await session.data(for: pageRequest)
        guard let http = pageResponse as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let page = String(data: pageData, encoding: .utf8)
        else { throw URLError(.badServerResponse) }

        let jsPath = try Self.firstMatch(in: page, pattern: #"/assets/index~[^/]+\.js"#)
        var scriptRequest = URLRequest(url: URL(string: "https://beta.music.apple.com" + jsPath)!)
        scriptRequest.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        let (scriptData, scriptResponse) = try await session.data(for: scriptRequest)
        guard let scriptHTTP = scriptResponse as? HTTPURLResponse, (200 ..< 300).contains(scriptHTTP.statusCode),
              let script = String(data: scriptData, encoding: .utf8)
        else { throw URLError(.badServerResponse) }

        return try Self.firstMatch(in: script, pattern: #"eyJ[A-Za-z0-9\-_=]+\.[A-Za-z0-9\-_=]+\.[A-Za-z0-9\-_=]+"#)
    }

    // MARK: - Response parsing

    /// Converts a Paxsenix lyrics response into the highest-fidelity result:
    /// word-synced (TTML/ELRC) > line-synced (ELRC/LRC) > plain > content.
    static func parse(_ response: PaxsenixLyricsResponse, source: String = "Paxsenix") -> LyricResult {
        var bestResult: LyricResult = .unavailable
        var bestRank = -1

        if let ttml = response.ttmlContent,
           !ttml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let synced = Self.parseTTML(ttml, source: source),
           !synced.isEmpty
        {
            bestResult = .synced(synced)
            bestRank = synced.hasWordTiming ? 2 : 1
        }

        for elrc in [response.elrcMultiPerson, response.elrc] {
            guard let elrc, !elrc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let synced = Self.parseELRC(elrc, source: source),
                  !synced.isEmpty
            else { continue }
            let rank = synced.hasWordTiming ? 2 : 1
            if rank > bestRank {
                bestResult = .synced(synced)
                bestRank = rank
            }
        }

        if bestRank < 2,
           let plain = response.plain,
           !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            bestResult = .plain(Lyrics(text: plain, source: source))
            bestRank = 0
        }

        if bestRank < 2, let content = response.content, !content.isEmpty {
            let contentResult = Self.parseContent(content, syllable: response.type == "Syllable", source: source)
            if contentResult.isAvailable, contentResult.capabilityRank > bestRank {
                bestResult = contentResult
            }
        }

        return bestResult
    }

    /// Parses the ELRC format: `[mm:ss.cc]{agent}text` lines followed by
    /// `<word:start:end|word:start:end>` word-timing lines (times in seconds).
    static func parseELRC(_ raw: String, source: String = "Paxsenix") -> SyncedLyrics? {
        var timed: [(timeMs: Int, text: String, words: [TimedWord]?)] = []
        var pendingWords: [TimedWord]?

        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("<"), line.hasSuffix(">"),
               let words = Self.parseWordTimingLine(line), !words.isEmpty
            {
                if !timed.isEmpty {
                    timed[timed.count - 1].words = words
                } else {
                    pendingWords = words
                }
                continue
            }

            guard let (timeMs, rest) = Self.parseLRCTime(line) else { continue }
            let text = Self.stripAgents(rest).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            timed.append((timeMs, text, pendingWords))
            pendingWords = nil
        }

        guard !timed.isEmpty else { return nil }
        var lines: [SyncedLyricLine] = []
        for (index, entry) in timed.enumerated() {
            let nextMs = index + 1 < timed.count ? timed[index + 1].timeMs : entry.timeMs + 4_000
            lines.append(SyncedLyricLine(
                timeInMs: entry.timeMs,
                duration: max(1, nextMs - entry.timeMs),
                text: entry.text,
                words: entry.words
            ))
        }
        return SyncedLyrics(lines: lines, source: source)
    }

    /// Parses Apple Music TTML: `<p begin end>` blocks whose `<span>` children
    /// may carry per-word `begin` timings.
    static func parseTTML(_ raw: String, source: String = "Paxsenix") -> SyncedLyrics? {
        TTMLParser.parse(raw, source: source)
    }

    /// Builds a result from the structured `content` array: word-synced when the
    /// response type is Syllable, plain text otherwise.
    static func parseContent(_ content: [PaxsenixLyricsResponse.ContentLine], syllable: Bool, source: String = "Paxsenix") -> LyricResult {
        if syllable {
            var lines: [SyncedLyricLine] = []
            for (index, line) in content.enumerated() {
                let rawUnits = line.text ?? []
                var words: [TimedWord] = []
                var previousWasPart = false
                for (unitIndex, unit) in rawUnits.enumerated() {
                    guard let unitText = unit.text, !unitText.isEmpty, let wordMs = unit.timestamp else { continue }
                    var rendered = unitText
                    // Glue syllable parts of the same word together; insert a
                    // single space only at word boundaries (or when the source
                    // already carries leading whitespace).
                    if unitIndex > 0, !previousWasPart,
                       !rendered.hasPrefix(" "), !rendered.hasPrefix("\t")
                    {
                        rendered = " " + rendered
                    }
                    words.append(TimedWord(timeInMs: wordMs, word: rendered))
                    previousWasPart = unit.part == true
                }
                let text = words.isEmpty
                    ? (rawUnits.compactMap(\.text).joined())
                    : words.map(\.word).joined()
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let startMs = line.timestamp ?? 0
                let nextMs = index + 1 < content.count ? (content[index + 1].timestamp ?? startMs) : startMs + 4_000
                lines.append(SyncedLyricLine(
                    timeInMs: startMs,
                    duration: max(1, nextMs - startMs),
                    text: text,
                    words: words.isEmpty ? nil : words
                ))
            }
            guard !lines.isEmpty else { return .unavailable }
            return .synced(SyncedLyrics(lines: lines, source: source))
        }

        let plain = content.compactMap { line -> String? in
            let joined = line.text?.compactMap(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces) ?? ""
            return joined.isEmpty ? nil : joined
        }.joined(separator: "\n")
        guard !plain.isEmpty else { return .unavailable }
        return .plain(Lyrics(text: plain, source: source))
    }

    // MARK: - Matching

    static func cleanTitle(_ title: String) -> String {
        var cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for pattern in Self.titleCleanupPatterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanArtist(_ artist: String) -> String {
        let cleaned = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in Self.artistSeparators {
            if let range = cleaned.range(of: separator, options: .caseInsensitive) {
                return String(cleaned[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return cleaned
    }

    static func scoreAndFilter(
        _ results: [PaxsenixTrack],
        title: String,
        artist: String,
        duration: TimeInterval?
    ) -> [PaxsenixTrack] {
        let cleanupRegex = #"\s*\(.*?\)|\s*\[.*?\]"#
        let cleanedTitle = Self.scoringClean(title, cleanupRegex: cleanupRegex)
        let cleanedArtist = Self.cleanArtist(artist).lowercased()
        let targetIsMixed = title.lowercased().contains("mixed")
        let targetIsRemix = title.lowercased().contains("remix")

        let scored = results.map { track -> (PaxsenixTrack, Double) in
            var score = 0.0

            if let trackDuration = track.duration, let targetDuration = duration {
                let diff = abs(Double(trackDuration) - targetDuration)
                if diff <= 2 { score += 100 }
                else if diff <= 5 { score += 50 }
                else if diff <= 10 { score += 10 }
                else { score -= 50 }
            }

            let trackTitle = Self.scoringClean(track.name, cleanupRegex: cleanupRegex)
            if trackTitle == cleanedTitle {
                score += 80
            } else if trackTitle.contains(cleanedTitle) || cleanedTitle.contains(trackTitle) {
                score += 40
            }

            let trackIsMixed = track.name.lowercased().contains("mixed")
            let trackIsRemix = track.name.lowercased().contains("remix")
            if trackIsMixed && !targetIsMixed { score -= 60 }
            if trackIsRemix && !targetIsRemix { score -= 40 }

            let trackArtistLower = track.artist.lowercased()
            if trackArtistLower.contains(cleanedArtist) {
                score += 50
            } else {
                let artistWords = cleanedArtist
                    .split(whereSeparator: \.isWhitespace)
                    .filter { $0.count > 2 }
                if artistWords.contains(where: { trackArtistLower.contains($0) }) {
                    score += 25
                }
            }

            return (track, score)
        }

        return scored
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(10)
            .map(\.0)
    }

    private static func scoringClean(_ text: String, cleanupRegex: String) -> String {
        text.replacingOccurrences(of: cleanupRegex, with: "", options: .regularExpression)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - ELRC helpers

    private static func parseWordTimingLine(_ line: String) -> [TimedWord]? {
        let inner = line.dropFirst().dropLast()
        var words: [TimedWord] = []
        for entry in inner.split(separator: "|") {
            let parts = entry.split(separator: ":")
            guard parts.count >= 3,
                  let startSeconds = Double(parts[parts.count - 2])
            else { continue }
            let word = parts.dropLast(2).joined(separator: ":")
            words.append(TimedWord(timeInMs: max(0, Int(startSeconds * 1000)), word: String(word)))
        }
        return words.isEmpty ? nil : Self.normalizeWordSpacing(words)
    }

    /// Ensures every word after the first starts with a single space so karaoke
    /// rendering doesn't glue words together. Idempotent for payloads that
    /// already include leading whitespace (Apple TTML spans).
    static func normalizeWordSpacing(_ words: [TimedWord]) -> [TimedWord] {
        var result: [TimedWord] = []
        result.reserveCapacity(words.count)
        for (index, timedWord) in words.enumerated() {
            let word = timedWord.word
            if index > 0 && !word.hasPrefix(" ") && !word.hasPrefix("\t") {
                result.append(TimedWord(timeInMs: timedWord.timeInMs, word: " " + word))
            } else {
                result.append(timedWord)
            }
        }
        return result
    }

    private static func parseLRCTime(_ line: String) -> (Int, String)? {
        let pattern = #"^\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\](.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let minutesRange = Range(match.range(at: 1), in: line),
              let secondsRange = Range(match.range(at: 2), in: line)
        else { return nil }

        let minutes = Int(line[minutesRange]) ?? 0
        let seconds = Int(line[secondsRange]) ?? 0
        var fractionMs = 0
        if match.range(at: 3).location != NSNotFound, let fractionRange = Range(match.range(at: 3), in: line) {
            let fraction = String(line[fractionRange])
            let value = Int(fraction) ?? 0
            fractionMs = fraction.count == 1 ? value * 100 : (fraction.count == 2 ? value * 10 : value)
        }
        let rest: String
        if match.range(at: 4).location != NSNotFound, let restRange = Range(match.range(at: 4), in: line) {
            rest = String(line[restRange])
        } else {
            rest = ""
        }
        return ((minutes * 60 + seconds) * 1000 + fractionMs, rest)
    }

    private static func stripAgents(_ text: String) -> String {
        text.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
    }

    // MARK: - Decoding types

    private struct AppleSearchResponse: Decodable {
        let results: Results?
        let resources: Resources?
        struct Results: Decodable { let songs: Songs? }
        struct Songs: Decodable { let data: [SongReference]? }
        struct SongReference: Decodable {
            let id: String
            let attributes: SongAttributes?
        }
        struct Resources: Decodable { let songs: [String: SongResource]? }
        struct SongResource: Decodable { let attributes: SongAttributes? }
        struct SongAttributes: Decodable {
            let name: String?
            let artistName: String?
            let durationInMillis: Int?
        }
    }

    private static func firstMatch(in string: String, pattern: String) throws -> String {
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) else {
            throw URLError(.cannotParseResponse)
        }
        if match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: string) {
            return String(string[range])
        }
        guard let range = Range(match.range, in: string) else { throw URLError(.cannotParseResponse) }
        return String(string[range])
    }

    // MARK: - Constants

    private static let titleCleanupPatterns: [String] = [
        #"\s*\(.*?(official|video|audio|lyrics|lyric|visualizer|hd|hq|4k|remaster|remix|live|acoustic|version|edit|extended|radio|clean|explicit).*?\)"#,
        #"\s*\[.*?(official|video|audio|lyrics|lyric|visualizer|hd|hq|4k|remaster|remix|live|acoustic|version|edit|extended|radio|clean|explicit).*?\]"#,
        #"\s*【.*?】"#,
        #"\s*\|.*$"#,
        #"\s*-\s*(official|video|audio|lyrics|lyric|visualizer).*$"#,
        #"\s*\(feat\..*?\)"#,
        #"\s*\(ft\..*?\)"#,
        #"\s*feat\..*$"#,
        #"\s*ft\..*$"#,
        #"\s*\([^)]*\d{4}[^)]*\)"#,
    ]

    private static let artistSeparators = [" & ", " and ", ", ", " x ", " X ", " feat. ", " feat ", " ft. ", " ft ", " featuring ", " with "]
}

// MARK: - Public model types

/// A lightweight, testable Apple Music search result.
struct PaxsenixTrack: Sendable, Equatable {
    let id: String
    let name: String
    let artist: String
    let duration: Int? // seconds
}

/// The lyrics response from `lyrics.paxsenix.org`.
struct PaxsenixLyricsResponse: Decodable {
    let type: String?
    let ttmlContent: String?
    let elrcMultiPerson: String?
    let elrc: String?
    let plain: String?
    let content: [ContentLine]?

    struct ContentLine: Decodable {
        let timestamp: Int?
        let background: Bool?
        let oppositeTurn: Bool?
        let text: [ContentWord]?
    }

    struct ContentWord: Decodable {
        let text: String?
        let timestamp: Int?
        let endtime: Int?
        /// True when this unit is a non-final part (syllable) of a word. The
        /// following unit belongs to the same word and must be glued to it.
        let part: Bool?

        init(text: String?, timestamp: Int?, endtime: Int?, part: Bool? = nil) {
            self.text = text
            self.timestamp = timestamp
            self.endtime = endtime
            self.part = part
        }
    }
}

// MARK: - Token cache

private actor PaxsenixTokenStore {
    private var token: String?

    func cachedToken() -> String? { self.token }
    func setToken(_ token: String) { self.token = token }
    func clearToken() { self.token = nil }
}

private struct AppleMusicAuthError: Error {}
