import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.service), .serialized)
struct LyricsProviderSettingsTests {
    private let ordered: [SettingsManager.LyricsProviderID] = [.betterLyrics, .paxsenix, .kugou, .lrclib]

    // MARK: - Enabled filtering

    @Test("enabledLyricsProviders preserves order and drops disabled providers")
    func enabledFiltersDisabled() {
        let enabled = SettingsManager.enabledLyricsProviders(
            order: self.ordered,
            disabled: [.paxsenix, .lrclib]
        )
        #expect(enabled == [.betterLyrics, .kugou])
    }

    @Test("enabledLyricsProviders returns everything when nothing is disabled")
    func enabledKeepsAll() {
        #expect(SettingsManager.enabledLyricsProviders(order: self.ordered, disabled: []) == self.ordered)
    }

    // MARK: - Reordering

    @Test("reorder moves a provider to the front")
    func reorderToFront() {
        let moved = SettingsManager.reorderedLyricsProviders(self.ordered, from: IndexSet(integer: 3), to: 0)
        #expect(moved == [.lrclib, .betterLyrics, .paxsenix, .kugou])
    }

    @Test("reorder moves a provider to the end")
    func reorderToEnd() {
        let moved = SettingsManager.reorderedLyricsProviders(self.ordered, from: IndexSet(integer: 0), to: 4)
        #expect(moved == [.paxsenix, .kugou, .lrclib, .betterLyrics])
    }

    @Test("reorder moves a middle provider one slot down")
    func reorderMiddle() {
        let moved = SettingsManager.reorderedLyricsProviders(self.ordered, from: IndexSet(integer: 1), to: 3)
        #expect(moved == [.betterLyrics, .kugou, .paxsenix, .lrclib])
    }

    @Test("reorder ignores out-of-range indices")
    func reorderIgnoresInvalid() {
        let moved = SettingsManager.reorderedLyricsProviders(self.ordered, from: IndexSet(integer: 9), to: 0)
        #expect(moved == self.ordered)
    }

    @Test("dropping a provider onto a later row lands it at that row's position")
    func dropOntoLaterRow() {
        let moved = SettingsManager.reorderedLyricsProviders(self.ordered, moving: .betterLyrics, onto: .kugou)
        #expect(moved == [.paxsenix, .kugou, .betterLyrics, .lrclib])
    }

    @Test("dropping a provider onto an earlier row lands it at that row's position")
    func dropOntoEarlierRow() {
        let moved = SettingsManager.reorderedLyricsProviders(self.ordered, moving: .lrclib, onto: .paxsenix)
        #expect(moved == [.betterLyrics, .lrclib, .paxsenix, .kugou])
    }

    @Test("dropping a provider onto itself is a no-op")
    func dropOntoSelf() {
        let moved = SettingsManager.reorderedLyricsProviders(self.ordered, moving: .kugou, onto: .kugou)
        #expect(moved == self.ordered)
    }

    // MARK: - Legacy migration

    @Test("legacy single-choice presets migrate to a disabled-provider set")
    func legacyMigration() {
        #expect(SettingsManager.disabledProvidersForLegacyChoice("paxsenixAndLRCLib").isEmpty)
        #expect(SettingsManager.disabledProvidersForLegacyChoice(nil).isEmpty)
        #expect(SettingsManager.disabledProvidersForLegacyChoice("betterLyrics") == [.paxsenix, .kugou, .lrclib])
        #expect(SettingsManager.disabledProvidersForLegacyChoice("kugouAndLRCLib") == [.betterLyrics, .paxsenix])
        #expect(SettingsManager.disabledProvidersForLegacyChoice("lrclib") == [.betterLyrics, .paxsenix, .kugou])
    }

    // MARK: - Status probe

    @Test("probe reports available when the host answers, even with a 404")
    func probeAvailable() async {
        defer { StatusProbeURLProtocol.handler = nil }
        StatusProbeURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let status = await LyricsProviderStatusService.probe(.lrclib, session: StatusProbeURLProtocol.makeSession())
        #expect(status == .available)
    }

    @Test("probe reports unavailable on a server error")
    func probeServerError() async {
        defer { StatusProbeURLProtocol.handler = nil }
        StatusProbeURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let status = await LyricsProviderStatusService.probe(.lrclib, session: StatusProbeURLProtocol.makeSession())
        #expect(status == .unavailable)
    }

    @Test("probe reports unavailable when the request fails")
    func probeNetworkError() async {
        defer { StatusProbeURLProtocol.handler = nil }
        StatusProbeURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        let status = await LyricsProviderStatusService.probe(.betterLyrics, session: StatusProbeURLProtocol.makeSession())
        #expect(status == .unavailable)
    }

    @Test("every provider has a probe URL")
    func everyProviderHasProbeURL() {
        for provider in SettingsManager.LyricsProviderID.allCases {
            #expect(provider.probeURL != nil)
        }
    }
}

// MARK: - Test double

/// A file-private URL protocol so these tests never race with other suites on
/// the shared `MockURLProtocol` handler.
private final class StatusProbeURLProtocol: URLProtocol {
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
