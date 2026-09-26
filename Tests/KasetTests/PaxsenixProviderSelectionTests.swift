import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.service), .serialized)
struct PaxsenixProviderSelectionTests {
    @Test("parse keeps a line-synced TTML result instead of downgrading to plain")
    func lineSyncedSurvivesPlain() {
        let response = PaxsenixLyricsResponse(
            type: "Line",
            ttmlContent: #"<tt><body><div><p begin="0.26" end="5.444">What a night to run away</p></div></body></tt>"#,
            elrcMultiPerson: nil,
            elrc: nil,
            plain: "[Intro]\nWhat a night to run away",
            content: nil
        )

        let result = PaxsenixProvider.parse(response)

        guard case let .synced(lyrics) = result else {
            Issue.record("Expected synced result, got \(result)")
            return
        }
        #expect(lyrics.hasWordTiming == false)
        #expect(lyrics.lines.first?.text == "What a night to run away")
    }

    @Test("parse keeps a line-synced ELRC result instead of downgrading to plain")
    func lineSyncedELRCSurvivesPlain() {
        let response = PaxsenixLyricsResponse(
            type: "Line",
            ttmlContent: nil,
            elrcMultiPerson: nil,
            elrc: "[00:12.00]First line\n[00:16.00]Second line",
            plain: "First line\nSecond line",
            content: nil
        )

        let result = PaxsenixProvider.parse(response)

        guard case let .synced(lyrics) = result else {
            Issue.record("Expected synced result, got \(result)")
            return
        }
        #expect(lyrics.lines.count == 2)
    }

    @Test("parse falls back to plain text when nothing is synced")
    func plainFallbackWhenNothingSynced() {
        let response = PaxsenixLyricsResponse(
            type: "Line",
            ttmlContent: nil,
            elrcMultiPerson: nil,
            elrc: nil,
            plain: "Just some plain lyrics",
            content: nil
        )

        guard case let .plain(lyrics) = PaxsenixProvider.parse(response) else {
            Issue.record("Expected plain result")
            return
        }
        #expect(lyrics.text == "Just some plain lyrics")
    }

    @Test("prefers the best-matching track over a higher-fidelity different song")
    func prefersBestMatchOverWrongSong() async {
        defer { PaxsenixURLProtocol.handler = nil }
        let fetchedIDs = IDBox()
        PaxsenixURLProtocol.handler = { request in
            let host = request.url?.host ?? ""
            let path = request.url?.path ?? ""

            if host == "beta.music.apple.com", path.isEmpty || path == "/" {
                return Self.ok(request, "<html><head><script src=\"/assets/index~abc123.js\"></script></head></html>")
            }
            if host == "beta.music.apple.com", path.hasPrefix("/assets/index~") {
                return Self.ok(request, "const t=\"eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJ4In0.abc123\";")
            }
            if host == "amp-api.music.apple.com" {
                return Self.ok(request, Self.searchPayload)
            }
            if host == "lyrics.paxsenix.org" {
                let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "id" })?.value ?? ""
                fetchedIDs.append(id)
                return Self.ok(request, id == "111" ? Self.primaryLyricsPayload : Self.wrongSongLyricsPayload)
            }
            return Self.ok(request, "{}")
        }

        let provider = PaxsenixProvider(session: PaxsenixURLProtocol.makeSession())
        let info = LyricsSearchInfo(
            title: "What a Night",
            artist: "Kim Petras",
            album: nil,
            duration: 153.6,
            videoId: "video-paxsenix-select"
        )

        let result = await provider.search(info: info)

        guard case let .synced(lyrics) = result else {
            Issue.record("Expected synced result, got \(result)")
            return
        }
        #expect(lyrics.lines.first?.text == "What a night to run away")
        #expect(lyrics.hasWordTiming == false)
        #expect(fetchedIDs.values == ["111"])
    }

    // MARK: - Fixtures

    private static let searchPayload = """
    {
      "results": { "songs": { "data": [ { "id": "111" }, { "id": "222" } ] } },
      "resources": {
        "songs": {
          "111": { "attributes": { "name": "What a Night", "artistName": "Kim Petras", "durationInMillis": 153605 } },
          "222": { "attributes": { "name": "When We Were Young (The Logical Song)", "artistName": "David Guetta & Kim Petras", "durationInMillis": 147433 } }
        }
      }
    }
    """

    private static let primaryLyricsPayload = """
    {
      "type": "Line",
      "ttmlContent": "<tt><body><div><p begin=\\"0.26\\" end=\\"5.444\\">What a night to run away</p></div></body></tt>",
      "plain": "[Intro]\\nWhat a night to run away"
    }
    """

    private static let wrongSongLyricsPayload = """
    {
      "type": "Word",
      "ttmlContent": "<tt><body><div><p begin=\\"1.0\\" end=\\"3.0\\"><span begin=\\"1.0\\">When</span> <span begin=\\"1.2\\">we</span> <span begin=\\"1.4\\">were</span> <span begin=\\"1.6\\">young</span></p></div></body></tt>"
    }
    """

    private static func ok(_ request: URLRequest, _ body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}

// MARK: - Test doubles

/// Thread-safe capture of the lyric ids the provider actually fetched.
private final class IDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []

    func append(_ id: String) {
        self.lock.lock()
        self.ids.append(id)
        self.lock.unlock()
    }

    var values: [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.ids
    }
}

/// A file-private URL protocol so these tests never race with other suites on
/// the shared `MockURLProtocol` handler.
private final class PaxsenixURLProtocol: URLProtocol {
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
