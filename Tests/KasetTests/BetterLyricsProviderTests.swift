import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.service), .serialized)
struct BetterLyricsProviderTests {
    // MARK: - TTML parsing

    @Test("Parses Apple Music TTML word spans into word-synced lyrics")
    func parsesWordSyncedTTML() {
        let raw = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body><div>
            <p begin="00:00:01.500" end="00:00:04.000">
              <span begin="00:00:01.500" end="00:00:02.100">I</span> <span begin="00:00:02.200" end="00:00:03.000">been</span>
            </p>
          </div></body>
        </tt>
        """

        let result = TTMLParser.parse(raw, source: "BetterLyrics")

        #expect(result?.lines.count == 1)
        #expect(result?.hasWordTiming == true)
        #expect(result?.source == "BetterLyrics")
        #expect(result?.lines[0].text == "I been")
        #expect(result?.lines[0].timeInMs == 1500)
        #expect(result?.lines[0].words?.map(\.word) == ["I", " been"])
    }

    @Test("Skips translation and romanization spans")
    func skipsTranslationAndRomanizationSpans() {
        let raw = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <body><div>
            <p begin="00:00:01.000" end="00:00:03.000">
              <span begin="00:00:01.000" end="00:00:01.500">Hello</span> <span begin="00:00:01.500" end="00:00:02.000">world</span>
              <span ttm:role="x-translation" begin="00:00:01.000" end="00:00:02.000">Bonjour</span>
              <span ttm:role="x-roman" begin="00:00:01.000" end="00:00:02.000">haro</span>
            </p>
          </div></body>
        </tt>
        """

        let result = TTMLParser.parse(raw, source: "BetterLyrics")

        #expect(result?.lines.count == 1)
        #expect(result?.lines[0].text == "Hello world")
        #expect(result?.lines[0].words?.count == 2)
    }

    @Test("Returns nil for TTML with no timed lines")
    func nilForEmptyTTML() {
        #expect(TTMLParser.parse("<tt><body><div></div></body></tt>", source: "BetterLyrics") == nil)
        #expect(TTMLParser.parse("not xml", source: "BetterLyrics") == nil)
    }

    // MARK: - Response decoding

    @Test("Decodes a TTML response payload")
    func decodesResponse() throws {
        let json = #"{"ttml":"<tt/>","extra":"ignored"}"#
        let response = try JSONDecoder().decode(BetterLyricsResponse.self, from: Data(json.utf8))
        #expect(response.ttml == "<tt/>")
    }

    // MARK: - Search

    @Test("search requests the exact title and artist and returns synced lyrics")
    func searchReturnsSyncedLyrics() async throws {
        defer { BetterLyricsURLProtocol.handler = nil }
        let box = URLBox()
        BetterLyricsURLProtocol.handler = { request in
            box.set(request.url)
            let ttml = """
            <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
              <p begin="00:00:01.000" end="00:00:03.000">
                <span begin="00:00:01.000" end="00:00:01.500">Hello</span> <span begin="00:00:01.500" end="00:00:02.000">world</span>
              </p>
            </div></body></tt>
            """
            let data = try JSONEncoder().encode(["ttml": ttml])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let provider = BetterLyricsProvider(session: BetterLyricsURLProtocol.makeSession())
        let info = LyricsSearchInfo(
            title: "Blinding Lights",
            artist: "The Weeknd",
            album: "After Hours",
            duration: 200.4,
            videoId: "video-betterlyrics"
        )

        let result = await provider.search(info: info)

        guard case let .synced(lyrics) = result else {
            Issue.record("Expected synced result")
            return
        }
        #expect(lyrics.hasWordTiming)
        #expect(lyrics.source == "BetterLyrics")

        let url = try #require(box.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(url.path == "/getLyrics")
        let items = Dictionary(uniqueKeysWithValues: components.queryItems?.map { ($0.name, $0.value) } ?? [])
        #expect(items["s"] == "Blinding Lights")
        #expect(items["a"] == "The Weeknd")
        #expect(items["d"] == "200")
        #expect(items["al"] == "After Hours")
    }

    @Test("search returns unavailable when the service has no lyrics")
    func searchUnavailableWithoutTTML() async {
        defer { BetterLyricsURLProtocol.handler = nil }
        let body = Data(#"{"ttml":null}"#.utf8)
        BetterLyricsURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body)
        }

        let provider = BetterLyricsProvider(session: BetterLyricsURLProtocol.makeSession())
        let result = await provider.search(info: Self.makeSearchInfo())

        #expect(result == .unavailable)
    }

    @Test("search returns unavailable on a server error")
    func searchUnavailableOnServerError() async {
        defer { BetterLyricsURLProtocol.handler = nil }
        BetterLyricsURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let provider = BetterLyricsProvider(session: BetterLyricsURLProtocol.makeSession())
        let result = await provider.search(info: Self.makeSearchInfo())

        #expect(result == .unavailable)
    }

    private static func makeSearchInfo() -> LyricsSearchInfo {
        LyricsSearchInfo(
            title: "Song",
            artist: "Artist",
            album: nil,
            duration: nil,
            videoId: "video-1"
        )
    }
}

// MARK: - Test doubles

/// Thread-safe capture of the last request URL, since the mock handler runs off
/// the test's actor.
private final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedURL: URL?

    func set(_ url: URL?) {
        self.lock.lock()
        self.storedURL = url
        self.lock.unlock()
    }

    var url: URL? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storedURL
    }
}

/// A file-private URL protocol so these tests never race with other suites on
/// the shared `MockURLProtocol` handler.
private final class BetterLyricsURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Self.self]
        return URLSession(configuration: configuration)
    }
}
