import Foundation

// MARK: - UnisonEnvelope

/// Every Unison response is wrapped in `{ success, data }`. `success` must be
/// checked before `data` is read — a failed lookup keeps the envelope and adds
/// `code`/`error`/`hint` instead.
struct UnisonEnvelope: Decodable {
    let success: Bool
    let data: UnisonLyricsEntry?
}

/// `/lyrics/variants/:videoId` returns the same records as a list.
struct UnisonVariantsEnvelope: Decodable {
    let success: Bool
    let data: [UnisonLyricsEntry]?
}

/// A single Unison lyrics record. `format` says how to read `lyrics` (`ttml`,
/// `lrc`, or `plain`) and `syncType` how precise the timing is (`richsync`,
/// `linesync`, or `plain`).
struct UnisonLyricsEntry: Decodable, Sendable, Equatable {
    let id: Int?
    let videoId: String?
    let song: String?
    let artist: String?
    let album: String?
    let duration: TimeInterval?
    let format: String?
    let syncType: String?
    let language: String?
    let score: Int?
    let voteCount: Int?
    let confidence: String?
    let lyrics: String?
    let submitter: UnisonSubmitter?
}

/// The member who submitted a lyrics version. `keyId` is a public key-derived
/// identifier; Unison serves a profile for it at `/curator/<keyId>`.
struct UnisonSubmitter: Decodable, Sendable, Equatable {
    let keyId: String?
    let displayName: String?
    let avatarUrl: String?
}

// MARK: - UnisonProvider

/// Fetches lyrics from Unison (`unison.boidu.dev`), a public community-synced
/// lyrics database. No key and no sign-in are required.
///
/// Lookup order: the track's `videoId` first, since Unison is keyed on it and
/// the result is exact. When that misses, the title/artist (plus optional album
/// and duration) fall back. Entries declare their own `format`, so TTML becomes
/// word-synced lyrics, LRC line-synced lyrics, and plain text stays plain.
///
/// Every record credits its submitter, so the lyrics carry a
/// `LyricsAttribution`. Because a video can have several community versions,
/// the provider is also a `LyricsVariantProvider`: the service asks for the
/// rest of the list once Unison's result is displayed.
///
/// Unison rate limits reads to 120 requests per minute per IP, so a search
/// makes at most two requests (plus one variant list when Unison wins).
final class UnisonProvider: LyricsProvider {
    let name = "Unison"
    let capability: LyricsCapability = .word

    static let baseURL = URL(string: "https://unison.boidu.dev")!

    /// Unison lists up to 50 versions; only the best-ranked few are useful as a
    /// switcher, and every record carries a full lyrics body.
    static let variantLimit = 25

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
            if let entry = try await self.fetch(videoId: info.videoId),
               let result = Self.parse(entry, source: self.name),
               result.isAvailable
            {
                return result
            }
            if let entry = try await self.fetch(info: info),
               let result = Self.parse(entry, source: self.name),
               result.isAvailable
            {
                return result
            }
            return .unavailable
        } catch is CancellationError {
            return .unavailable
        } catch {
            DiagnosticsLogger.api.warning("Unison lyrics request failed: \(error.localizedDescription)")
            return .unavailable
        }
    }

    // MARK: - Requests

    private func fetch(videoId: String) async throws -> UnisonLyricsEntry? {
        guard let url = Self.lyricsURL(queryItems: [URLQueryItem(name: "v", value: videoId)]) else {
            throw URLError(.badURL)
        }
        guard let data = try await self.performRequest(url) else { return nil }
        let envelope = try JSONDecoder().decode(UnisonEnvelope.self, from: data)
        guard envelope.success else { return nil }
        return envelope.data
    }

    private func fetch(info: LyricsSearchInfo) async throws -> UnisonLyricsEntry? {
        var queryItems = [
            URLQueryItem(name: "song", value: info.title),
            URLQueryItem(name: "artist", value: info.artist),
        ]
        if let album = info.album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty {
            queryItems.append(URLQueryItem(name: "album", value: album))
        }
        if let duration = info.duration, duration > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        guard let url = Self.lyricsURL(queryItems: queryItems) else { throw URLError(.badURL) }
        guard let data = try await self.performRequest(url) else { return nil }
        let envelope = try JSONDecoder().decode(UnisonEnvelope.self, from: data)
        guard envelope.success else { return nil }
        return envelope.data
    }

    /// Runs a request and returns its body. A `404` means no lyrics matched,
    /// not an error.
    private func performRequest(_ url: URL) async throws -> Data? {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { return nil }
        guard (200 ..< 300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }

    // MARK: - Parsing

    /// Converts a Unison record into the highest-fidelity result its `format`
    /// supports, carrying the submitter's attribution. Returns `nil` when the
    /// payload carries no usable lyrics.
    static func parse(_ entry: UnisonLyricsEntry, source: String = "Unison") -> LyricResult? {
        guard let raw = entry.lyrics,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let attribution = Self.attribution(for: entry, providerName: source)

        switch entry.format?.lowercased() {
        case "ttml":
            guard let parsed = TTMLParser.parse(raw, source: source), !parsed.isEmpty else { return nil }
            return .synced(SyncedLyrics(lines: parsed.lines, source: source, attribution: attribution))
        case "lrc":
            guard let parsed = LRCParser.parse(raw), !parsed.isEmpty else { return nil }
            return .synced(SyncedLyrics(lines: parsed.lines, source: source, attribution: attribution))
        default:
            return .plain(Lyrics(text: raw, source: source, attribution: attribution))
        }
    }

    /// Credits the member who submitted the lyrics, with a link to their public
    /// Unison profile. Returns `nil` when the record carries no submitter.
    static func attribution(for entry: UnisonLyricsEntry, providerName: String = "Unison") -> LyricsAttribution? {
        guard let submitter = entry.submitter else { return nil }

        let name = submitter.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (name?.isEmpty == false) ? name : nil
        let profileURL = submitter.keyId.flatMap { keyId in
            URL(string: "https://unison.boidu.dev/curator/\(keyId)")
        }
        let avatarURL = submitter.avatarUrl.flatMap(URL.init(string:))

        guard displayName != nil || profileURL != nil || avatarURL != nil else { return nil }
        return LyricsAttribution(
            providerName: providerName,
            submitterName: displayName,
            submitterProfileURL: profileURL,
            submitterAvatarURL: avatarURL
        )
    }

    // MARK: - Variants

    private func fetchVariants(videoId: String) async throws -> [UnisonLyricsEntry] {
        let url = Self.baseURL
            .appendingPathComponent("lyrics")
            .appendingPathComponent("variants")
            .appendingPathComponent(videoId)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "limit", value: "\(Self.variantLimit)")]
        guard let finalURL = components.url else { throw URLError(.badURL) }
        guard let data = try await self.performRequest(finalURL) else { return [] }
        let envelope = try JSONDecoder().decode(UnisonVariantsEnvelope.self, from: data)
        guard envelope.success else { return [] }
        return envelope.data ?? []
    }

    /// Stable picker identifier: Unison's numeric record id when present.
    static func variantID(for entry: UnisonLyricsEntry, index: Int) -> String {
        if let id = entry.id { return String(id) }
        return "\(entry.videoId ?? "variant")-\(index)"
    }

    /// Short label shown in the variant picker: how precise the timing is, then
    /// who submitted it (falling back to the vetting level when unnamed).
    static func variantLabel(for entry: UnisonLyricsEntry) -> String {
        var parts = [Self.syncDescription(for: entry)]
        if let name = entry.submitter?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            parts.append(name)
        } else if let confidence = entry.confidence?.trimmingCharacters(in: .whitespacesAndNewlines), !confidence.isEmpty {
            parts.append(confidence.capitalized)
        }
        return parts.joined(separator: " · ")
    }

    private static func syncDescription(for entry: UnisonLyricsEntry) -> String {
        switch entry.syncType?.lowercased() {
        case "richsync": String(localized: "Word-synced")
        case "linesync": String(localized: "Line-synced")
        case "plain": String(localized: "Plain text")
        default:
            switch entry.format?.lowercased() {
            case "ttml": String(localized: "Synced")
            case "lrc": String(localized: "Line-synced")
            default: String(localized: "Plain text")
            }
        }
    }

    // MARK: - Constants

    private static func lyricsURL(queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent("lyrics"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems
        return components?.url
    }

    private static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Kaset/\(version)"
    }
}

// MARK: - LyricsVariantProvider

extension UnisonProvider: LyricsVariantProvider {
    /// Lists the community versions for a video, best-ranked first. Records that
    /// carry no usable lyrics are dropped.
    func variants(for info: LyricsSearchInfo) async -> [LyricsVariant] {
        do {
            let entries = try await self.fetchVariants(videoId: info.videoId)
            return entries.enumerated().compactMap { index, entry in
                guard let result = Self.parse(entry, source: self.name), result.isAvailable else { return nil }
                return LyricsVariant(
                    id: Self.variantID(for: entry, index: index),
                    label: Self.variantLabel(for: entry),
                    result: result
                )
            }
        } catch is CancellationError {
            return []
        } catch {
            DiagnosticsLogger.api.warning("Unison variants request failed: \(error.localizedDescription)")
            return []
        }
    }
}
