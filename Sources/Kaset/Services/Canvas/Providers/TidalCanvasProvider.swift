import Foundation

/// Fetches Tidal video covers (animated album art) from the public Tidal
/// catalog API.
///
/// Lookup order matters more than it looks. Tidal's search ranks a song's
/// *release* above everything else only when the album is left out of the
/// query: querying `"Miley Cyrus Flowers"` surfaces the "Flowers" single (which
/// carries a video cover), while `"Endless Summer Vacation Miley Cyrus Flowers"`
/// surfaces "Endless Summer Vacation" — whose entry has none — and buries the
/// single. The provider therefore tries the song + artist query first and only
/// falls back to album-qualified queries.
///
/// `searchAttempts(for:)` builds the ordered list of queries; `fetchCanvas`
/// runs them in order and returns the first candidate that passes validation
/// and carries a `videoCover`.
final class TidalCanvasProvider: CanvasProvider {
    let name = "Tidal"

    private static let baseURL = "https://api.tidal.com/v1/"
    /// Public embed-player token used by tidal.com web embeds (non-secret, same
    /// class as the API Explorer's public API key).
    private static let tidalToken = "vNVdglQOjFJJGG2U"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    private var countryCode: String {
        let country = Locale.current.region?.identifier ?? ""
        return country.count == 2 ? country.uppercased() : "US"
    }

    /// Caps the album-items requests the affiliation stage may make, so a miss
    /// cannot fan out into an unbounded number of network round trips.
    private static let maxAffiliationLookups = 3

    func fetchCanvas(for info: CanvasSearchInfo) async -> CanvasArtwork? {
        for attempt in Self.searchAttempts(for: info) {
            if Task.isCancelled { return nil }
            if let artwork = await self.searchCanvas(attempt: attempt) {
                return artwork
            }
        }

        // Last resort: the canvas may hang off an album no query can name.
        let song = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !song.isEmpty, !Task.isCancelled else { return nil }
        return await self.albumCanvasContainingSong(
            song: song,
            artist: info.artist.trimmingCharacters(in: .whitespacesAndNewlines),
            albumValidation: info.album?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Search plan

    /// One Tidal search plus the validations that decide whether a result may
    /// be used as a canvas for the requested track.
    struct SearchAttempt: Equatable, Sendable {
        let query: String
        let types: String
        let songValidation: String?
        let artistValidation: String?
        let albumValidation: String?
        let fallbackTitle: String
    }

    /// Builds the ordered search plan for a track, skipping attempts whose
    /// inputs are missing. Order is preference order; the first attempt that
    /// yields a validated candidate wins.
    ///
    /// 1. `TRACKS` on song + artist — the highest-signal query. A matched
    ///    track's nested album carries the same `videoCover` as the album
    ///    itself, and leaving the album out keeps the single ranked first.
    /// 2. `ALBUMS` on the known album + artist — the album-level video cover.
    /// 3. `ALBUMS` on song + artist, validated against the song title — catches
    ///    single-style releases whose album entry is titled after the song.
    /// 4. `TRACKS` on album + artist + song — the album-qualified query the
    ///    original implementation started with, kept as a last resort.
    static func searchAttempts(for info: CanvasSearchInfo) -> [SearchAttempt] {
        let song = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = info.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = info.album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var attempts: [SearchAttempt] = []

        let songQuery = Self.query([artist, song])
        if !song.isEmpty, !songQuery.isEmpty {
            attempts.append(SearchAttempt(
                query: songQuery,
                types: "TRACKS",
                songValidation: song,
                artistValidation: artist,
                albumValidation: nil,
                fallbackTitle: song
            ))
        }

        let albumQuery = Self.query([album, artist])
        if !album.isEmpty, !albumQuery.isEmpty {
            attempts.append(SearchAttempt(
                query: albumQuery,
                types: "ALBUMS",
                songValidation: nil,
                artistValidation: artist,
                albumValidation: album,
                fallbackTitle: album
            ))
        }

        if !song.isEmpty, !songQuery.isEmpty {
            attempts.append(SearchAttempt(
                query: songQuery,
                types: "ALBUMS",
                songValidation: nil,
                artistValidation: artist,
                // A single release is titled after the track it leads with.
                albumValidation: song,
                fallbackTitle: song
            ))
        }

        let albumQualifiedQuery = Self.query([album, artist, song])
        if !album.isEmpty, !song.isEmpty, !albumQualifiedQuery.isEmpty {
            attempts.append(SearchAttempt(
                query: albumQualifiedQuery,
                types: "TRACKS",
                songValidation: song,
                artistValidation: artist,
                albumValidation: nil,
                fallbackTitle: song
            ))
        }

        return attempts
    }

    private static func query(_ parts: [String]) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Search

    private func searchCanvas(attempt: SearchAttempt) async -> CanvasArtwork? {
        guard !attempt.query.isEmpty else { return nil }
        let sectionKey = attempt.types == "TRACKS" ? "tracks" : "albums"
        let response = await self.search(query: attempt.query, types: attempt.types)
        guard let section = Self.findSearchSection(in: response, key: sectionKey) else {
            DiagnosticsLogger.api.debug(
                "Tidal canvas: search for \"\(attempt.query, privacy: .public)\" (\(attempt.types, privacy: .public)) returned no \"\(sectionKey, privacy: .public)\" section"
            )
            return nil
        }
        let items = section["items"] as? [[String: Any]] ?? []
        DiagnosticsLogger.api.debug(
            "Tidal canvas: search \"\(attempt.query, privacy: .public)\" (\(attempt.types, privacy: .public)) got \(items.count) items"
        )

        for obj in items {
            guard let candidate = Self.extractCandidate(
                from: obj,
                songValidation: attempt.songValidation,
                artistValidation: attempt.artistValidation,
                albumValidation: attempt.albumValidation
            ) else {
                let rawTitle = obj["title"] as? String ?? "?"
                DiagnosticsLogger.api.debug(
                    "Tidal canvas: rejected candidate \"\(rawTitle, privacy: .public)\" (failed validation)"
                )
                continue
            }
            guard let videoCover = candidate.videoCover,
                  let videoURL = Self.formatVideoUrl(videoCover)
            else {
                DiagnosticsLogger.api.debug(
                    "Tidal canvas: candidate \"\(candidate.title ?? "?", privacy: .public)\" passed validation but has no videoCover"
                )
                continue
            }
            return CanvasArtwork(
                name: candidate.title ?? attempt.fallbackTitle,
                artist: candidate.artist,
                videoURL: videoURL,
                source: self.name,
                albumName: candidate.album
            )
        }
        return nil
    }

    // MARK: - Album affiliation

    /// One album that carries a video cover and whose track list still has to be
    /// checked for the requested song.
    private struct AlbumCandidate {
        let albumId: String
        let title: String
        let artist: String
        let videoCover: String
    }

    /// Finds an album canvas for a track by searching albums for the song and
    /// then *proving* the song is on the album.
    ///
    /// Tidal attaches a video cover to the album release, not to the track. The
    /// "Good Days" single carries none, but the `SOS` album the song also appears on
    /// does — and when the reported album is missing, a deluxe edition, or the single
    /// itself, nothing in the track's metadata names `SOS`, so no query can reach it.
    /// The album therefore has to be discovered and then verified against its track
    /// list. That verification is what keeps this safe: an album's canvas is only
    /// used when the album genuinely contains the requested song, so an artist's
    /// other canvased albums can never be shown for it.
    private func albumCanvasContainingSong(
        song: String,
        artist: String,
        albumValidation: String?
    ) async -> CanvasArtwork? {
        let query = Self.query([artist, song])
        guard !query.isEmpty else { return nil }

        let response = await self.search(query: query, types: "ALBUMS")
        guard let section = Self.findSearchSection(in: response, key: "albums"),
              let items = section["items"] as? [[String: Any]]
        else { return nil }

        // Only albums by a matching artist that actually carry a video cover are
        // worth an album-items request.
        var candidates: [AlbumCandidate] = []
        for obj in items {
            guard let videoCover = obj["videoCover"] as? String, !videoCover.isEmpty,
                  let albumId = Self.albumId(from: obj),
                  let title = obj["title"] as? String
            else { continue }
            let names = Self.artistNames(from: obj)
            guard Self.artistMatches(validation: artist, returned: names) else { continue }
            candidates.append(AlbumCandidate(
                albumId: albumId,
                title: title,
                artist: names.joined(separator: ", "),
                videoCover: videoCover
            ))
        }
        guard !candidates.isEmpty else { return nil }

        // Check the album the caller named first, then a single named after the
        // song, then search order.
        let ordered = candidates.sorted { lhs, rhs in
            Self.candidateRank(lhs.title, song: song, albumValidation: albumValidation)
                < Self.candidateRank(rhs.title, song: song, albumValidation: albumValidation)
        }

        for candidate in ordered.prefix(Self.maxAffiliationLookups) {
            if Task.isCancelled { return nil }
            guard let videoURL = Self.formatVideoUrl(candidate.videoCover) else { continue }
            guard await self.albumContainsTrack(albumId: candidate.albumId, title: song) else {
                DiagnosticsLogger.api.debug(
                    "Tidal canvas: album \"\(candidate.title, privacy: .public)\" has a video cover but does not contain \"\(song, privacy: .public)\""
                )
                continue
            }
            DiagnosticsLogger.api.debug(
                "Tidal canvas: affiliated \"\(song, privacy: .public)\" with album \"\(candidate.title, privacy: .public)\""
            )
            return CanvasArtwork(
                name: song,
                artist: candidate.artist,
                videoURL: videoURL,
                source: self.name,
                albumName: candidate.title
            )
        }
        return nil
    }

    /// Ranks an album title for affiliation: the caller's album first, then a
    /// release titled after the song, then everything else in search order.
    private static func candidateRank(
        _ albumTitle: String,
        song: String,
        albumValidation: String?
    ) -> Int {
        if let albumValidation, !albumValidation.isEmpty,
           CanvasMatching.normalizeForComparison(albumTitle)
           == CanvasMatching.normalizeForComparison(albumValidation)
        {
            return 0
        }
        return CanvasMatching.normalizeForComparison(albumTitle)
            == CanvasMatching.normalizeForComparison(song) ? 1 : 2
    }

    /// Whether an album's track list contains a track with the given title.
    private func albumContainsTrack(albumId: String, title: String) async -> Bool {
        guard var components = URLComponents(string: Self.baseURL + "albums/\(albumId)/items") else {
            return false
        }
        components.queryItems = [
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "countryCode", value: self.countryCode),
        ]
        guard let url = components.url else { return false }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(Self.tidalToken, forHTTPHeaderField: "X-Tidal-Token")

        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return Self.albumItemsContainTrack(json, title: title)
        } catch {
            return false
        }
    }

    /// Pure check over an `/albums/{id}/items` response. Each entry wraps its track
    /// in an `item` object, but the bare-track shape is accepted too.
    static func albumItemsContainTrack(_ response: [String: Any], title: String) -> Bool {
        guard let items = response["items"] as? [[String: Any]] else { return false }
        let target = CanvasMatching.normalizeForComparison(title)
        guard !target.isEmpty else { return false }
        for element in items {
            let track = (element["item"] as? [String: Any]) ?? element
            guard let trackTitle = track["title"] as? String else { continue }
            if CanvasMatching.normalizeForComparison(trackTitle) == target { return true }
        }
        return false
    }

    /// Tidal returns album IDs as JSON numbers.
    static func albumId(from obj: [String: Any]) -> String? {
        if let id = obj["id"] as? String { return id }
        if let id = obj["id"] as? NSNumber { return id.stringValue }
        return nil
    }

    private func search(query: String, types: String) async -> [String: Any] {
        guard var components = URLComponents(string: Self.baseURL + "search") else { return [:] }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "types", value: types),
            URLQueryItem(name: "countryCode", value: self.countryCode),
        ]
        guard let url = components.url else { return [:] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(Self.tidalToken, forHTTPHeaderField: "X-Tidal-Token")

        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                DiagnosticsLogger.api.error(
                    "Tidal canvas: search HTTP \(status) for \"\(query, privacy: .public)\""
                )
                return [:]
            }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } catch {
            DiagnosticsLogger.api.error("Tidal canvas search failed: \(error.localizedDescription)")
            return [:]
        }
    }

    // MARK: - Response parsing (internal for unit tests)

    /// A single search result that passed all validations.
    struct Candidate {
        let title: String?
        let artist: String
        let album: String?
        let videoCover: String?
    }

    /// Validates a Tidal search result item against the requested song, artist,
    /// and album, then extracts the video cover fields.
    static func extractCandidate(
        from obj: [String: Any],
        songValidation: String?,
        artistValidation: String?,
        albumValidation: String?
    ) -> Candidate? {
        let resultTitle = obj["title"] as? String

        let allArtistNames = Self.artistNames(from: obj)
        let combinedArtistStr = allArtistNames.joined(separator: ", ")

        // Strict song title match.
        if let songValidation, let resultTitle {
            guard CanvasMatching.normalizeForComparison(resultTitle)
                == CanvasMatching.normalizeForComparison(songValidation)
            else { return nil }
        }

        // Strict album title match.
        if let albumValidation, let resultTitle {
            guard CanvasMatching.normalizeForComparison(resultTitle)
                == CanvasMatching.normalizeForComparison(albumValidation)
            else { return nil }
        }

        guard Self.artistMatches(validation: artistValidation, returned: allArtistNames) else {
            return nil
        }

        // Tracks carry videoCover on the nested album object; album results
        // carry it on the item itself.
        let albumObj = obj["album"] as? [String: Any]
        let videoCover = (albumObj?["videoCover"] as? String) ?? (obj["videoCover"] as? String)
        let albumTitle = (albumObj?["title"] as? String) ?? resultTitle

        return Candidate(
            title: resultTitle,
            artist: combinedArtistStr,
            album: albumTitle,
            videoCover: videoCover
        )
    }

    /// The artist names on a search result: Tidal returns separate artist objects,
    /// with a single `artist` object as the fallback shape.
    static func artistNames(from obj: [String: Any]) -> [String] {
        if let artistsArray = obj["artists"] as? [[String: Any]] {
            let names = artistsArray.compactMap { $0["name"] as? String }
            if !names.isEmpty { return names }
        }
        if let single = (obj["artist"] as? [String: Any])?["name"] as? String {
            return [single]
        }
        return []
    }

    /// Whether every requested artist appears in a result's artist list. A nil or
    /// blank request passes (no artist constraint was asked for) — a whitespace-only
    /// value must not be treated as a constraint that nothing can satisfy.
    static func artistMatches(validation: String?, returned: [String]) -> Bool {
        guard let validation,
              !validation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return true }
        let requested = CanvasMatching.artistComponents(validation)
        let returnedNames = Set(returned.map(CanvasMatching.normalizeForComparison))
        return !requested.isEmpty && !returnedNames.isEmpty
            && requested.allSatisfy { returnedNames.contains($0) }
    }

    /// Formats a Tidal videoCover ID into a playable MP4 URL.
    static func formatVideoUrl(_ id: String) -> URL? {
        let parts = id.split(separator: "-")
        guard parts.count == 5 else { return nil }
        let path = parts.joined(separator: "/")
        return URL(string: "https://resources.tidal.com/videos/\(path)/1280x1280.mp4")
    }

    /// Recursively finds the search section (an object containing "items")
    /// reachable under the given key, e.g. `albums` or `tracks`.
    static func findSearchSection(in source: Any, key: String) -> [String: Any]? {
        if let dict = source as? [String: Any] {
            if dict["items"] is [[String: Any]] {
                return dict
            }
            if let nested = dict[key], let found = Self.findSearchSection(in: nested, key: key) {
                return found
            }
            for value in dict.values {
                if let found = Self.findSearchSection(in: value, key: key) {
                    return found
                }
            }
        } else if let array = source as? [Any] {
            for element in array {
                if let found = Self.findSearchSection(in: element, key: key) {
                    return found
                }
            }
        }
        return nil
    }
}
