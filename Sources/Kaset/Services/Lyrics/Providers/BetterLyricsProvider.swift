import Foundation

// MARK: - BetterLyricsResponse

/// Response from the BetterLyrics API (`/getLyrics`). It carries Apple Music
/// TTML, the same word-synced format Paxsenix returns.
struct BetterLyricsResponse: Decodable {
    let ttml: String?
}

// MARK: - BetterLyricsProvider

/// Fetches lyrics from the BetterLyrics API (`lyrics-api.boidu.dev`).
///
/// A single `/getLyrics` request maps a title and artist (plus optional
/// duration and album) to Apple Music TTML, which `TTMLParser` turns into
/// word-synced lyrics. A song that only has unsynced lyrics comes back as a
/// TTML document with no timing; the provider returns that as `.plain` so it
/// still reaches the display. The exact title and artist are sent — deliberately not
/// normalized — because normalizing can match a different edit (radio vs.
/// album) and return lyrics that drift out of sync.
final class BetterLyricsProvider: LyricsProvider {
    let name = "BetterLyrics"
    let capability: LyricsCapability = .word

    static let baseURL = URL(string: "https://lyrics-api.boidu.dev")!

    private let session: URLSession

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
            guard let ttml = try await self.fetchTTML(info: info) else {
                return .unavailable
            }
            if let synced = TTMLParser.parse(ttml, source: self.name), !synced.isEmpty {
                return .synced(synced)
            }
            // A song with only unsynced lyrics still comes back as TTML, but with
            // no timing. It belongs on the plain path so the lyrics system can
            // rank it against the other providers' results.
            if let plain = TTMLParser.plainLyrics(ttml, source: self.name) {
                return .plain(plain)
            }
            return .unavailable
        } catch is CancellationError {
            return .unavailable
        } catch {
            DiagnosticsLogger.api.warning("BetterLyrics request failed: \(error.localizedDescription)")
            return .unavailable
        }
    }

    // MARK: - Requests

    private func fetchTTML(info: LyricsSearchInfo) async throws -> String? {
        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent("getLyrics"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [
            URLQueryItem(name: "s", value: info.title),
            URLQueryItem(name: "a", value: info.artist),
        ]
        if let duration = info.duration, duration > 0 {
            queryItems.append(URLQueryItem(name: "d", value: String(Int(duration.rounded()))))
        }
        if let album = info.album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty {
            queryItems.append(URLQueryItem(name: "al", value: album))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(BetterLyricsResponse.self, from: data).ttml
    }

    // MARK: - Constants

    private static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Kaset/\(version)"
    }
}
