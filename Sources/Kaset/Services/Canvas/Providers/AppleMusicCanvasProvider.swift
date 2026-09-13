import Foundation

/// Fetches Apple Music artist motion artwork (HLS canvas) for the fullscreen
/// view. The catalog access token is discovered at runtime from the Apple Music
/// web player scripts — no credentials are embedded in the binary.
final class AppleMusicCanvasProvider: CanvasProvider {
    let name = "Apple Music"

    private static let ampBaseURL = "https://amp-api.music.apple.com"
    private static let musicAppleBaseURL = "https://music.apple.com"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 25
        return URLSession(configuration: configuration)
    }()

    private let tokenStore = TokenStore()

    // MARK: - CanvasProvider

    func fetchCanvas(for info: CanvasSearchInfo) async -> CanvasArtwork? {
        let storefront = Self.storefrontCode()
        guard let token = await self.tokenStore.token() else {
            DiagnosticsLogger.api.error("Apple Music canvas: no web player token available")
            return nil
        }

        // Try each artist component (e.g. "Drake, 21 Savage") until one with
        // motion artwork is found.
        let artists = CanvasMatching.artistComponents(info.artist)
        let candidates = artists.isEmpty ? [info.artist] : artists
        for artist in candidates {
            guard let artistId = await Self.findArtistId(
                artistName: artist,
                storefront: storefront,
                token: token
            ) else {
                DiagnosticsLogger.api.debug(
                    "Apple Music canvas: no artist ID found for \"\(artist, privacy: .public)\""
                )
                continue
            }
            DiagnosticsLogger.api.debug(
                "Apple Music canvas: found artist \"\(artist, privacy: .public)\" with ID \(artistId, privacy: .public), fetching motion artwork"
            )
            if let artwork = await Self.fetchMotionArtwork(
                artistId: artistId,
                storefront: storefront,
                token: token
            ) {
                return artwork
            }
        }
        return nil
    }

    // MARK: - Token discovery

    private static func storefrontCode() -> String {
        guard let region = Locale.current.region?.identifier, region.count == 2 else {
            return "us"
        }
        return region.lowercased()
    }

    /// A discovered web player JWT and its expiry (epoch milliseconds).
    struct DiscoveredToken: Equatable {
        let token: String
        let expiryMs: Int64
    }

    /// Caches the discovered token in an actor so concurrent lookups share one
    /// discovery pass.
    private actor TokenStore {
        private var cachedToken: String?
        private var tokenExpiryMs: Int64 = 0

        func token() async -> String? {
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            if let cachedToken, nowMs < self.tokenExpiryMs - 60000 {
                return cachedToken
            }
            guard let discovered = await AppleMusicCanvasProvider.fetchWebPlayerToken(),
                  discovered.expiryMs > nowMs
            else { return nil }
            self.cachedToken = discovered.token
            self.tokenExpiryMs = discovered.expiryMs
            return discovered.token
        }
    }

    /// Scrapes a fresh web player JWT from the Apple Music web player scripts.
    static func fetchWebPlayerToken() async -> DiscoveredToken? {
        do {
            let browseURL = URL(string: "\(Self.musicAppleBaseURL)/us/browse")!
            var browseRequest = URLRequest(url: browseURL)
            browseRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            let (html, response) = try await Self.session.data(for: browseRequest)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let htmlString = String(data: html, encoding: .utf8)
            else { return nil }

            let scriptRegex = try NSRegularExpression(pattern: #"/assets/index(?:-legacy)?[~-][a-zA-Z0-9_-]+\.js"#)
            let scriptPaths = Self.matches(scriptRegex, in: htmlString)
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

            for scriptPath in scriptPaths {
                let scriptURL = URL(string: "\(Self.musicAppleBaseURL)\(scriptPath)")!
                var scriptRequest = URLRequest(url: scriptURL)
                scriptRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
                let (data, scriptResponse) = try await Self.session.data(for: scriptRequest)
                guard let http = scriptResponse as? HTTPURLResponse,
                      http.statusCode == 200,
                      let script = String(data: data, encoding: .utf8)
                else { continue }

                let tokenRegex = try NSRegularExpression(pattern: #"ey[a-zA-Z0-9_-]+\.ey[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+"#)
                for token in Self.matches(tokenRegex, in: script) {
                    if let discovered = Self.validateToken(token, nowMs: nowMs) {
                        return discovered
                    }
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Validates a JWT-shaped token by decoding its payload and checking for an
    /// `iss` claim plus an unexpired `exp`. Pure function for unit tests.
    static func validateToken(_ token: String, nowMs: Int64) -> DiscoveredToken? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        guard let decoded = Self.decodeBase64URL(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any]
        else { return nil }
        guard json["iss"] != nil else { return nil }
        guard let exp = json["exp"] as? NSNumber, exp.int64Value * 1000 > nowMs else { return nil }
        return DiscoveredToken(token: token, expiryMs: exp.int64Value * 1000)
    }

    /// Decodes a base64url (JWT-safe alphabet) string.
    static func decodeBase64URL(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        return Data(base64Encoded: base64)
    }

    private static func matches(_ regex: NSRegularExpression, in string: String) -> [String] {
        let range = NSRange(string.startIndex..., in: string)
        return regex.matches(in: string, range: range).compactMap { match in
            Range(match.range, in: string).map { String(string[$0]) }
        }
    }

    // MARK: - Catalog lookups

    /// Searches the catalog for an artist by name and returns the best
    /// scoring match's ID.
    static func findArtistId(artistName: String, storefront: String, token: String) async -> String? {
        guard !artistName.isEmpty else { return nil }
        guard var components = URLComponents(string: "\(Self.ampBaseURL)/v1/catalog/\(storefront)/search") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "term", value: artistName),
            URLQueryItem(name: "types", value: "artists"),
            URLQueryItem(name: "limit", value: "3"),
        ]
        var request = URLRequest(url: components.url!)
        Self.applyAMPHeaders(to: &request, token: token)

        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }

            let results = (json["results"] as? [String: Any])?["artists"] as? [String: Any]
            let items = results?["data"] as? [[String: Any]] ?? []

            let scored = items.compactMap { obj -> (score: Int, id: String)? in
                guard let attributes = obj["attributes"] as? [String: Any],
                      let resultName = attributes["name"] as? String,
                      let id = obj["id"] as? String
                else { return nil }

                let matches = CanvasMatching.containsIgnoringCase(resultName, artistName)
                    || CanvasMatching.containsIgnoringCase(artistName, resultName)
                guard matches else { return nil }

                let score = CanvasMatching.equalsIgnoringCase(resultName, artistName) ? 10 : 5
                return (score, id)
            }.sorted { $0.score > $1.score }

            return scored.first(where: { $0.score >= 4 })?.id
        } catch {
            return nil
        }
    }

    /// Fetches an artist profile with editorial video/artwork extensions and
    /// extracts the motion video URL.
    static func fetchMotionArtwork(artistId: String, storefront: String, token: String) async -> CanvasArtwork? {
        DiagnosticsLogger.api.debug(
            "Apple Music canvas: fetching motion artwork for artist ID \(artistId, privacy: .public)"
        )
        guard var components = URLComponents(
            string: "\(Self.ampBaseURL)/v1/catalog/\(storefront)/artists/\(artistId)"
        ) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "extend", value: "editorialVideo,editorialArtwork"),
        ]
        var request = URLRequest(url: components.url!)
        Self.applyAMPHeaders(to: &request, token: token)

        do {
            let (data, response) = try await Self.session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataArray = json["data"] as? [[String: Any]],
                  let artistObj = dataArray.first,
                  let attributes = artistObj["attributes"] as? [String: Any]
            else { return nil }

            guard let videoURL = Self.extractEditorialVideoURL(from: attributes) else { return nil }
            return CanvasArtwork(
                name: attributes["name"] as? String,
                artist: nil,
                videoURL: videoURL,
                source: "Apple Music",
                albumName: nil
            )
        } catch {
            return nil
        }
    }

    private static func applyAMPHeaders(to request: inout URLRequest, token: String) {
        request.timeoutInterval = 25
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.apple.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    }

    // MARK: - Motion video extraction (internal for unit tests)

    /// Extracts the motion video URL from an artist's attributes, preferring
    /// `editorialVideo` over `editorialArtwork`.
    static func extractEditorialVideoURL(from attributes: [String: Any]) -> URL? {
        if let editorialVideo = attributes["editorialVideo"] as? [String: Any],
           let url = Self.videoURL(in: editorialVideo)
        {
            return url
        }
        if let editorialArtwork = attributes["editorialArtwork"] as? [String: Any],
           let url = Self.videoURL(in: editorialArtwork)
        {
            return url
        }
        return nil
    }

    /// Finds a motion video URL inside an editorial data object, honoring the
    /// preferred key order before falling back to any nested `video` string.
    static func videoURL(in editorialData: [String: Any]) -> URL? {
        let preferredKeys = [
            "motionDetailRaw",
            "motionDetailTall",
            "motionDetailSquare",
            "motionSquareVideo1x1",
            "motionTallVideo3x4",
        ]
        for key in preferredKeys {
            if let video = (editorialData[key] as? [String: Any])?["video"] as? String,
               let url = Self.validVideoURL(video)
            {
                return url
            }
        }
        for (_, value) in editorialData {
            if let dict = value as? [String: Any],
               let video = dict["video"] as? String,
               let url = Self.validVideoURL(video)
            {
                return url
            }
        }
        return nil
    }

    private static func validVideoURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return url
    }
}
