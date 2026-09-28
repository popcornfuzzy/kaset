import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.service), .serialized)
struct UnisonProviderTests {
    // MARK: - Video lookup

    @Test("search fetches by video id and parses richsync TTML into word-synced lyrics")
    func fetchesByVideoId() async throws {
        defer { UnisonURLProtocol.handler = nil }
        let log = UnisonRequestLog()
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
          <p begin="00:00:01.000" end="00:00:03.000">
            <span begin="00:00:01.000" end="00:00:01.500">Hello</span> <span begin="00:00:01.500" end="00:00:02.000">world</span>
          </p>
        </div></body></tt>
        """
        UnisonURLProtocol.handler = { request in
            log.append(request.url)
            let payload: [String: Any] = [
                "success": true,
                "data": [
                    "id": 4_821,
                    "videoId": "dQw4w9WgXcQ",
                    "song": "Never Gonna Give You Up",
                    "artist": "Rick Astley",
                    "album": "Whenever You Need Somebody",
                    "duration": 213,
                    "format": "ttml",
                    "syncType": "richsync",
                    "language": "en",
                    "confidence": "high",
                    "lyrics": ttml,
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, data)
        }

        let provider = UnisonProvider(session: UnisonURLProtocol.makeSession())
        let result = await provider.search(info: Self.makeSearchInfo(videoId: "dQw4w9WgXcQ"))

        guard case let .synced(lyrics) = result else {
            Issue.record("Expected synced result")
            return
        }
        #expect(lyrics.source == "Unison")
        #expect(lyrics.hasWordTiming)
        #expect(lyrics.lines.map(\.text) == ["Hello world"])

        let url = try #require(log.all.first)
        #expect(url.path == "/lyrics")
        let items = Self.queryItems(of: url)
        #expect(items["v"] == "dQw4w9WgXcQ")
    }

    // MARK: - Song/artist fallback

    @Test("falls back to song and artist when the video lookup misses")
    func fallsBackToSongAndArtist() async throws {
        defer { UnisonURLProtocol.handler = nil }
        let log = UnisonRequestLog()
        UnisonURLProtocol.handler = { request in
            log.append(request.url)
            let items = Self.queryItems(of: request.url)
            if items["v"] != nil {
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data(#"{"success":false,"error":"Not found","code":"NOT_FOUND"}"#.utf8))
            }
            let payload: [String: Any] = [
                "success": true,
                "data": [
                    "videoId": "other-video",
                    "format": "lrc",
                    "syncType": "linesync",
                    "lyrics": "[00:01.00]Line one\n[00:04.00]Line two",
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        let provider = UnisonProvider(session: UnisonURLProtocol.makeSession())
        let info = LyricsSearchInfo(
            title: "Blinding Lights",
            artist: "The Weeknd",
            album: "After Hours",
            duration: 200.4,
            videoId: "video-unison-fallback"
        )

        let result = await provider.search(info: info)

        guard case let .synced(lyrics) = result else {
            Issue.record("Expected synced result")
            return
        }
        #expect(lyrics.source == "Unison")
        #expect(lyrics.hasWordTiming == false)
        #expect(lyrics.lines.map(\.text).contains("Line one"))

        #expect(log.all.count == 2)
        let fallback = try #require(log.all.last)
        #expect(fallback.path == "/lyrics")
        let items = Self.queryItems(of: fallback)
        #expect(items["song"] == "Blinding Lights")
        #expect(items["artist"] == "The Weeknd")
        #expect(items["album"] == "After Hours")
        #expect(items["duration"] == "200")
    }

    // MARK: - Formats

    @Test("plain format returns plain lyrics")
    func plainFormat() async {
        defer { UnisonURLProtocol.handler = nil }
        UnisonURLProtocol.handler = { request in
            let payload: [String: Any] = [
                "success": true,
                "data": ["format": "plain", "syncType": "plain", "lyrics": "First line\nSecond line"],
            ]
            let data = try! JSONSerialization.data(withJSONObject: payload)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        let provider = UnisonProvider(session: UnisonURLProtocol.makeSession())
        let result = await provider.search(info: Self.makeSearchInfo(videoId: "video-plain"))

        guard case let .plain(lyrics) = result else {
            Issue.record("Expected plain result")
            return
        }
        #expect(lyrics.source == "Unison")
        #expect(lyrics.text == "First line\nSecond line")
    }

    // MARK: - Misses and errors

    @Test("returns unavailable when the envelope reports failure")
    func unavailableOnEnvelopeFailure() async {
        defer { UnisonURLProtocol.handler = nil }
        UnisonURLProtocol.handler = { request in
            let body = Data(#"{"success":false,"error":"Not found","code":"NOT_FOUND","hint":"No lyrics matched that lookup yet."}"#.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let provider = UnisonProvider(session: UnisonURLProtocol.makeSession())
        let result = await provider.search(info: Self.makeSearchInfo(videoId: "video-miss"))
        #expect(result == .unavailable)
    }

    @Test("returns unavailable when data carries no lyrics")
    func unavailableWithoutLyrics() async {
        defer { UnisonURLProtocol.handler = nil }
        UnisonURLProtocol.handler = { request in
            let body = Data(#"{"success":true,"data":{"videoId":"v","format":"ttml"}}"#.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let provider = UnisonProvider(session: UnisonURLProtocol.makeSession())
        let result = await provider.search(info: Self.makeSearchInfo(videoId: "video-empty"))
        #expect(result == .unavailable)
    }

    @Test("returns unavailable on a server error")
    func unavailableOnServerError() async {
        defer { UnisonURLProtocol.handler = nil }
        UnisonURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let provider = UnisonProvider(session: UnisonURLProtocol.makeSession())
        let result = await provider.search(info: Self.makeSearchInfo(videoId: "video-error"))
        #expect(result == .unavailable)
    }

    // MARK: - Decoding

    @Test("decodes a lyrics entry payload")
    func decodesEntry() throws {
        let json = #"{"success":true,"data":{"id":4821,"videoId":"dQw4w9WgXcQ","format":"ttml","syncType":"richsync","confidence":"high","lyrics":"<tt/>"}}"#
        let envelope = try JSONDecoder().decode(UnisonEnvelope.self, from: Data(json.utf8))
        #expect(envelope.success)
        #expect(envelope.data?.id == 4_821)
        #expect(envelope.data?.confidence == "high")
        #expect(envelope.data?.lyrics == "<tt/>")
    }

    // MARK: - Attribution

    @Test("credits the submitter with a public profile link")
    func creditsSubmitter() throws {
        let entry = try Self.decodeEntry("""
        {"id":7,"videoId":"v","format":"plain","syncType":"plain","lyrics":"Line",
         "submitter":{"keyId":"abc123","displayName":"Curator","avatarUrl":"https://cdn.example/avatar.png","reputation":5}}
        """)

        let attribution = try #require(UnisonProvider.attribution(for: entry))
        #expect(attribution.providerName == "Unison")
        #expect(attribution.submitterName == "Curator")
        #expect(attribution.submitterProfileURL?.absoluteString == "https://unison.boidu.dev/curator/abc123")
        #expect(attribution.submitterAvatarURL?.absoluteString == "https://cdn.example/avatar.png")
        #expect(attribution.hasSubmitter)
    }

    @Test("parsed lyrics carry the submitter attribution")
    func parseAttachesAttribution() throws {
        let entry = try Self.decodeEntry("""
        {"id":1,"videoId":"v","format":"plain","syncType":"plain","lyrics":"Hello",
         "submitter":{"keyId":"k1","displayName":"Maker"}}
        """)

        guard case let .plain(lyrics) = UnisonProvider.parse(entry) else {
            Issue.record("Expected plain result")
            return
        }
        #expect(lyrics.attribution?.submitterName == "Maker")
        #expect(lyrics.attribution?.submitterProfileURL?.absoluteString == "https://unison.boidu.dev/curator/k1")
    }

    @Test("a record without a submitter carries no attribution")
    func noSubmitterNoAttribution() throws {
        let entry = try Self.decodeEntry(#"{"id":1,"videoId":"v","format":"plain","lyrics":"Hello"}"#)
        #expect(UnisonProvider.attribution(for: entry) == nil)
    }

    // MARK: - Variants

    @Test("variants lists community versions and drops unparseable records")
    func listsVariants() async throws {
        defer { UnisonURLProtocol.handler = nil }
        let log = UnisonRequestLog()
        let ttml = """
        <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
          <p begin="00:00:01.000" end="00:00:02.000">
            <span begin="00:00:01.000" end="00:00:02.000">Hi</span>
          </p>
        </div></body></tt>
        """
        UnisonURLProtocol.handler = { request in
            log.append(request.url)
            let payload: [String: Any] = [
                "success": true,
                "data": [
                    ["id": 10, "videoId": "v", "format": "ttml", "syncType": "richsync", "lyrics": ttml,
                     "submitter": ["keyId": "k1", "displayName": "Maker"]],
                    ["id": 11, "videoId": "v", "format": "lrc", "syncType": "linesync", "lyrics": "[00:01.00]Line", "confidence": "low"],
                    // No timed lines: this version has nothing to render.
                    ["id": 12, "videoId": "v", "format": "ttml", "syncType": "richsync", "lyrics": "<tt></tt>"],
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }

        let provider = UnisonProvider(session: UnisonURLProtocol.makeSession())
        let variants = await provider.variants(for: Self.makeSearchInfo(videoId: "v"))

        #expect(variants.count == 2)
        #expect(variants.first?.id == "10")
        #expect(variants.first?.label == "Word-synced · Maker")
        #expect(variants.first?.result.isAvailable == true)
        #expect(variants.last?.id == "11")
        #expect(variants.last?.label == "Line-synced · Low")

        let url = try #require(log.all.first)
        #expect(url.path == "/lyrics/variants/v")
        #expect(Self.queryItems(of: url)["limit"] == "25")
    }

    @Test("variants returns empty when the envelope reports failure")
    func variantsEmptyOnFailure() async {
        defer { UnisonURLProtocol.handler = nil }
        UnisonURLProtocol.handler = { request in
            let body = Data(#"{"success":false,"error":"Not found","code":"NOT_FOUND"}"#.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let provider = UnisonProvider(session: UnisonURLProtocol.makeSession())
        #expect(await provider.variants(for: Self.makeSearchInfo(videoId: "v")).isEmpty)
    }

    // MARK: - Helpers

    /// Decodes a bare record (the object that `data` wraps) for parser tests.
    private static func decodeEntry(_ json: String) throws -> UnisonLyricsEntry {
        let envelope = try JSONDecoder().decode(
            UnisonEnvelope.self,
            from: Data(#"{"success":true,"data":"#.utf8) + Data(json.utf8) + Data("}".utf8)
        )
        return try #require(envelope.data)
    }

    private static func makeSearchInfo(videoId: String) -> LyricsSearchInfo {
        LyricsSearchInfo(
            title: "Song",
            artist: "Artist",
            album: nil,
            duration: nil,
            videoId: videoId
        )
    }

    private static func queryItems(of url: URL?) -> [String: String] {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
        return Dictionary(uniqueKeysWithValues: components.queryItems?.compactMap { item in
            item.value.map { (item.name, $0) }
        } ?? [])
    }
}

// MARK: - Test doubles

/// Thread-safe record of the request URLs, since the mock handler runs off the
/// test's actor.
private final class UnisonRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL?) {
        guard let url else { return }
        self.lock.lock()
        self.urls.append(url)
        self.lock.unlock()
    }

    var all: [URL] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.urls
    }
}

/// A file-private URL protocol so these tests never race with other suites on
/// the shared `MockURLProtocol` handler.
private final class UnisonURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return URLSession(configuration: configuration)
    }
}
