import Foundation

@MainActor
@Observable
final class SyncedLyricsService {
    private struct InFlightSearch {
        let id: UUID
        let flight: SearchFlight
    }

    var currentLyrics: LyricResult = .unavailable
    var activeProvider: String?
    /// Provider currently being attempted; useful for loading-state feedback.
    var loadingProvider: String?
    var currentLyricsVideoId: String?
    var isLoading = false
    /// True while a lower-fidelity result is on screen but a higher-fidelity
    /// provider is still searching (drives the "Still searching for lyrics"
    /// shimmer). Cleared when the search completes or the best possible
    /// capability has already arrived.
    var searchingForBetterLyrics = false
    var errorMessage: String?

    private var providers: [LyricsProvider]
    private var cache: [String: LyricResult] = [:]
    private let cacheStore: LyricsCacheStore?
    private var fetchGeneration = 0
    private var inFlightSearches: [String: InFlightSearch] = [:]

    init(providers: [LyricsProvider]? = nil, cacheStore: LyricsCacheStore? = nil) {
        self.providers = providers ?? Self.providersForCurrentSettings()
        self.cacheStore = cacheStore
    }

    private static func providersForCurrentSettings() -> [LyricsProvider] {
        SettingsManager.shared.enabledLyricsProviders.map(Self.makeProvider)
    }

    private static func makeProvider(for id: SettingsManager.LyricsProviderID) -> LyricsProvider {
        switch id {
        case .betterLyrics: BetterLyricsProvider()
        case .paxsenix: PaxsenixProvider()
        case .kugou: KuGoProvider()
        case .lrclib: LRCLibProvider()
        }
    }

    func reloadProviderFromSettings() {
        self.providers = Self.providersForCurrentSettings()
        self.fetchGeneration += 1
        for flight in self.inFlightSearches.values {
            Task { await flight.flight.cancel() }
        }
        self.inFlightSearches.removeAll()
        self.cacheStore?.removeAll(except: nil)
        self.currentLyrics = .unavailable
        self.activeProvider = nil
        self.loadingProvider = nil
        self.currentLyricsVideoId = nil
        self.errorMessage = nil
        self.isLoading = false
        self.searchingForBetterLyrics = false
    }

    func clearCache(keepCurrent: Bool = true) {
        self.cache.removeAll()
        for flight in self.inFlightSearches.values {
            Task { await flight.flight.cancel() }
        }
        self.inFlightSearches.removeAll()
        self.cacheStore?.removeAll(except: keepCurrent ? self.currentLyricsVideoId : nil)
        if !keepCurrent {
            self.currentLyrics = .unavailable
            self.activeProvider = nil
            self.loadingProvider = nil
            self.currentLyricsVideoId = nil
            self.isLoading = false
            self.searchingForBetterLyrics = false
        }
    }

    func fetchLyrics(for info: LyricsSearchInfo, forceRefresh: Bool = false) async {
        guard !self.providers.isEmpty else {
            self.currentLyrics = .unavailable
            self.activeProvider = nil
            self.loadingProvider = nil
            self.currentLyricsVideoId = info.videoId
            self.errorMessage = String(localized: "No lyrics providers are enabled.")
            self.isLoading = false
            self.searchingForBetterLyrics = false
            return
        }

        // A presentation transition can make fullscreen and sidebar request the
        // same track at nearly the same time. Share that search rather than
        // letting one view invalidate the other with a second request.
        if !forceRefresh, let inFlight = self.inFlightSearches[info.videoId] {
            self.isLoading = true
            self.loadingProvider = self.providers.first?.name
            let resolved = await inFlight.flight.value()
            self.finishSearch(resolved, for: info.videoId, requestID: self.fetchGeneration, flightID: inFlight.id)
            return
        }

        // Lyrics are already loaded for this track. Serve them immediately
        // instead of searching again — opening fullscreen (or re-opening the
        // sidebar) must not re-run the provider pipeline.
        if !forceRefresh,
           self.currentLyricsVideoId == info.videoId,
           self.currentLyrics.isAvailable
        {
            self.activeProvider = Self.source(of: self.currentLyrics)
            self.isLoading = false
            self.searchingForBetterLyrics = false
            return
        }

        self.fetchGeneration += 1
        let requestID = self.fetchGeneration
        let cached = forceRefresh ? nil : self.cachedResult(for: info.videoId)

        if let cached {
            self.apply(cached, provider: Self.source(of: cached), videoId: info.videoId, requestID: requestID)
            return
        }

        self.isLoading = true
        self.loadingProvider = self.providers.first?.name
        self.errorMessage = nil
        self.searchingForBetterLyrics = false
        if forceRefresh {
            self.cache.removeValue(forKey: info.videoId)
            self.cacheStore?.remove(for: info.videoId)
            // Treat a refresh like a fresh load: clear the displayed result so
            // the concurrent search behaves exactly like opening the lyrics
            // panel on a new song — the first result appears immediately and
            // better results swap in with the shimmer.
            self.currentLyrics = .unavailable
            self.currentLyricsVideoId = nil
        }

        let flightID = UUID()
        let flight = SearchFlight()
        let providers = self.providers
        self.inFlightSearches[info.videoId] = InFlightSearch(id: flightID, flight: flight)

        // The search runs directly in the caller's task; the shared flight lets
        // a concurrent caller for the same track await the same result instead
        // of launching a second search.
        let resolved = await Self.searchProviders(providers: providers, info: info) { [weak self] resolved in
            self?.applySearchResult(
                resolved,
                videoId: info.videoId,
                requestID: requestID,
                providers: providers
            )
        }
        await flight.fulfill(resolved)
        self.finishSearch(resolved, for: info.videoId, requestID: requestID, flightID: flightID)
    }

    private func finishSearch(
        _ resolved: ResolvedLyrics,
        for videoId: String,
        requestID: Int,
        flightID: UUID
    ) {
        if self.inFlightSearches[videoId]?.id == flightID {
            self.inFlightSearches.removeValue(forKey: videoId)
        }

        guard requestID == self.fetchGeneration else { return }
        if !resolved.result.isAvailable {
            self.errorMessage = "No lyrics were found from the selected sources."
        }

        // The best result across all providers is what future plays should read.
        self.searchingForBetterLyrics = false
        self.store(resolved.result, for: videoId)
        self.apply(
            resolved.result,
            provider: resolved.providerName,
            videoId: videoId,
            requestID: requestID
        )
    }

    /// Applies a provider result the moment it arrives during a concurrent
    /// search. The first valid result is displayed immediately; a later result
    /// replaces it only when it is strictly better (word > line > plain).
    private func applySearchResult(
        _ resolved: ResolvedLyrics,
        videoId: String,
        requestID: Int,
        providers: [LyricsProvider]
    ) {
        guard requestID == self.fetchGeneration, resolved.result.isAvailable else { return }

        let displayedRank = self.currentLyricsVideoId == videoId ? self.currentLyrics.capabilityRank : -1
        guard resolved.capability.rawValue > displayedRank else { return }

        self.apply(resolved.result, provider: resolved.providerName, videoId: videoId, requestID: requestID)

        let maxCapability = providers.map(\.capability).max() ?? .plain
        self.searchingForBetterLyrics = providers.count > 1 && resolved.capability < maxCapability
    }

    /// Searches every provider concurrently. Valid results are reported as they
    /// arrive so the first one can be displayed immediately; the returned value
    /// is the highest-fidelity result found across all providers.
    @MainActor
    private static func searchProviders(
        providers: [LyricsProvider],
        info: LyricsSearchInfo,
        onResult: @MainActor (ResolvedLyrics) -> Void
    ) async -> ResolvedLyrics {
        var best: ResolvedLyrics?

        await withTaskGroup(of: ResolvedLyrics.self) { group in
            for provider in providers {
                group.addTask {
                    let result = await provider.search(info: info)
                    return ResolvedLyrics(
                        result: result,
                        providerName: provider.name,
                        capability: result.capability
                    )
                }
            }

            for await resolved in group {
                guard resolved.result.isAvailable else { continue }
                onResult(resolved)
                if let currentBest = best {
                    if resolved.capability > currentBest.capability {
                        best = resolved
                    }
                } else {
                    best = resolved
                }
            }
        }

        guard let best else {
            return ResolvedLyrics(result: .unavailable, providerName: nil, capability: .plain)
        }
        return best
    }

    func fallbackToPlainLyrics(_ lyrics: Lyrics, videoId: String) {
        guard !self.currentLyrics.isAvailable || self.currentLyricsVideoId != videoId else { return }
        let result: LyricResult = lyrics.isAvailable ? .plain(lyrics) : .unavailable
        self.store(result, for: videoId)
        self.apply(result, provider: lyrics.source, videoId: videoId, requestID: self.fetchGeneration)
    }

    private func cachedResult(for videoId: String) -> LyricResult? {
        let result = self.cache[videoId] ?? self.cacheStore?.load(for: videoId)
        guard let result else { return nil }
        self.cache[videoId] = result
        return result
    }

    private func store(_ result: LyricResult, for videoId: String) {
        self.cache[videoId] = result
        self.cacheStore?.save(result, for: videoId)
    }

    private func apply(_ result: LyricResult, provider: String?, videoId: String, requestID: Int) {
        guard requestID == self.fetchGeneration else { return }
        self.currentLyrics = result
        self.activeProvider = provider ?? Self.source(of: result)
        self.loadingProvider = nil
        self.currentLyricsVideoId = videoId
        self.isLoading = false
        if case .synced = result {
            SingletonPlayerWebView.shared.startLyricsPoll()
            SingletonPlayerWebView.shared.sendCurrentLyricsTime()
        } else {
            SingletonPlayerWebView.shared.stopLyricsPoll()
        }
    }

    private static func source(of result: LyricResult) -> String? {
        switch result {
        case let .synced(lyrics): lyrics.source
        case let .plain(lyrics): lyrics.source
        case .unavailable: nil
        }
    }

    func migrateLegacyCacheIfNeeded() async {
        guard let cacheStore else { return }
        _ = await Task.detached(priority: .utility) {
            cacheStore.migrateLegacyCacheIfNeeded()
        }.value
    }
}

// MARK: - SearchFlight

/// The outcome of a finished search: the best result found across providers
/// plus the provider that produced it.
private struct ResolvedLyrics: Sendable {
    let result: LyricResult
    let providerName: String?
    let capability: LyricsCapability
}

/// A single shared in-flight search. The first caller runs the search and
/// fulfills the flight; concurrent callers for the same track await the same
/// result instead of launching a second search.
private actor SearchFlight {
    private var result: ResolvedLyrics?
    private var isCancelled = false
    private var waiters: [CheckedContinuation<ResolvedLyrics, Never>] = []

    func value() async -> ResolvedLyrics {
        if let result { return result }
        if self.isCancelled {
            return ResolvedLyrics(result: LyricResult.unavailable, providerName: nil, capability: LyricsCapability.plain)
        }
        return await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func fulfill(_ value: ResolvedLyrics) {
        guard self.result == nil, !self.isCancelled else { return }
        self.result = value
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: value)
        }
    }

    /// Marks the flight cancelled so waiting callers resolve to `.unavailable`
    /// instead of hanging (e.g. when the provider set is reloaded).
    func cancel() {
        guard self.result == nil, !self.isCancelled else { return }
        self.isCancelled = true
        let waiters = self.waiters
        self.waiters.removeAll()
        let unavailable = ResolvedLyrics(result: LyricResult.unavailable, providerName: nil, capability: LyricsCapability.plain)
        for waiter in waiters {
            waiter.resume(returning: unavailable)
        }
    }
}
