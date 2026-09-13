import Foundation

/// Fetches Tidal video covers (animated album art) from the public Tidal
/// catalog API. Album-level lookups are preferred because they are the closest
/// match to a square album artwork; track-level lookups are the fallback.
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

    func fetchCanvas(for info: CanvasSearchInfo) async -> CanvasArtwork? {
        // Prefer an album-level match: a video cover for the album itself is
        // the best fit for replacing the album artwork.
        if let album = info.album, !album.isEmpty {
            let query = "\(album) \(info.artist)"
            if let artwork = await self.searchCanvas(
                query: query,
                types: "ALBUMS",
                sectionKey: "albums",
                songValidation: nil,
                artistValidation: info.artist,
                albumValidation: album,
                fallbackTitle: album
            ) {
                return artwork
            }
        }

        // Fall back to a track-level match.
        let query: String
        if let album = info.album, !album.isEmpty {
            query = "\(album) \(info.artist) \(info.title)"
        } else {
            query = "\(info.artist) \(info.title)"
        }
        return await self.searchCanvas(
            query: query,
            types: "TRACKS",
            sectionKey: "tracks",
            songValidation: info.title,
            artistValidation: info.artist,
            albumValidation: nil,
            fallbackTitle: info.title
        )
    }

    // MARK: - Search

    private func searchCanvas(
        query: String,
        types: String,
        sectionKey: String,
        songValidation: String?,
        artistValidation: String?,
        albumValidation: String?,
        fallbackTitle: String
    ) async -> CanvasArtwork? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let response = await self.search(query: query, types: types)
        guard let section = Self.findSearchSection(in: response, key: sectionKey) else {
            DiagnosticsLogger.api.debug(
                "Tidal canvas: search for \"\(query, privacy: .public)\" (\(types, privacy: .public)) returned no \"\(sectionKey, privacy: .public)\" section"
            )
            return nil
        }
        let items = section["items"] as? [[String: Any]] ?? []
        DiagnosticsLogger.api.debug(
            "Tidal canvas: search \"\(query, privacy: .public)\" (\(types, privacy: .public)) got \(items.count) items"
        )

        for obj in items {
            guard let candidate = Self.extractCandidate(
                from: obj,
                songValidation: songValidation,
                artistValidation: artistValidation,
                albumValidation: albumValidation
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
                name: candidate.title ?? fallbackTitle,
                artist: candidate.artist,
                videoURL: videoURL,
                source: self.name,
                albumName: candidate.album
            )
        }
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

        // Tidal returns separate artist objects; collect all their names.
        let allArtistNames: [String]
        if let artistsArray = obj["artists"] as? [[String: Any]] {
            allArtistNames = artistsArray.compactMap { ($0["name"] as? String) }
        } else {
            allArtistNames = []
        }
        let combinedArtistStr: String
        if !allArtistNames.isEmpty {
            combinedArtistStr = allArtistNames.joined(separator: ", ")
        } else {
            combinedArtistStr = (obj["artist"] as? [String: Any])?["name"] as? String ?? ""
        }

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

        // Artist match: every requested artist must appear in the result.
        if let artistValidation, !artistValidation.isEmpty {
            let requested = CanvasMatching.artistComponents(artistValidation)
            let returned = Set(allArtistNames.map(CanvasMatching.normalizeForComparison))
            let matches = !requested.isEmpty && !returned.isEmpty
                && requested.allSatisfy { returned.contains($0) }
            guard matches else { return nil }
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
