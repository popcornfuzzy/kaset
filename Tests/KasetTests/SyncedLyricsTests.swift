import Foundation
import Testing
@testable import Kaset

// MARK: - SyncedLyricsTests

@Suite(.tags(.model))
struct SyncedLyricsTests {
    @Test("Line statuses computation")
    func lineStatuses() {
        let lines = [
            SyncedLyricLine(timeInMs: 0, duration: 10000, text: "Wait for it...", words: nil),
            SyncedLyricLine(timeInMs: 10000, duration: 5000, text: "Line 1", words: nil),
            SyncedLyricLine(timeInMs: 15000, duration: 5000, text: "Line 2", words: nil),
        ]
        let lyrics = SyncedLyrics(lines: lines, source: "Test")

        let statuses1 = lyrics.lineStatuses(at: 5000)
        #expect(statuses1 == [.current, .upcoming, .upcoming])

        let statuses2 = lyrics.lineStatuses(at: 12000)
        #expect(statuses2 == [.previous, .current, .upcoming])

        let statuses3 = lyrics.lineStatuses(at: 16000)
        #expect(statuses3 == [.previous, .previous, .current])

        let currentIdx = lyrics.currentLineIndex(at: 12000)
        #expect(currentIdx == 1)
    }
}

// MARK: - SyncedLyricsServiceTests

@Suite(.serialized, .tags(.service))
@MainActor
struct SyncedLyricsServiceTests {
    @Test("fetchLyrics prefers synced results over plain results")
    func fetchLyricsPrefersSyncedResults() async {
        let plain = Lyrics(text: "Plain lyrics", source: "Plain Source")
        let synced = Self.makeSyncedLyrics(source: "Synced Source", lineText: "Synced line")
        let service = SyncedLyricsService(providers: [
            MockLyricsProvider(name: "PlainProvider", result: .plain(plain)),
            MockLyricsProvider(name: "SyncedProvider", result: .synced(synced)),
        ])

        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-synced"))

        #expect(service.currentLyrics == .synced(synced))
        #expect(service.activeProvider == "SyncedProvider")
        #expect(service.isLoading == false)
    }

    @Test("equal-fidelity plain results keep the first arrival without replacement")
    func equalFidelityKeepsFirstArrival() async {
        let gate = SearchGate()
        let ytMusicPlain = Lyrics(text: "YTMusic lyrics", source: "YTMusic Source")
        let geniusPlain = Lyrics(text: "Genius lyrics", source: "Genius")
        let service = SyncedLyricsService(providers: [
            MockLyricsProvider(name: "Genius", result: .plain(geniusPlain), gate: gate),
            MockLyricsProvider(name: "YTMusic", result: .plain(ytMusicPlain)),
        ])
        let info = Self.makeSearchInfo(videoId: "video-equal-fidelity")

        let task = Task { @MainActor in
            await service.fetchLyrics(for: info)
        }

        // YTMusic returns instantly while Genius is still pending.
        await gate.waitUntilStarted()
        while !service.currentLyrics.isAvailable { await Task.yield() }

        #expect(service.currentLyrics == .plain(ytMusicPlain))
        #expect(service.activeProvider == "YTMusic")
        #expect(service.isLoading == false)

        // Same capability: the later Genius result does not replace it.
        await gate.release()
        await task.value

        #expect(service.currentLyrics == .plain(ytMusicPlain))
        #expect(service.activeProvider == "YTMusic")
    }

    @Test("word-synced Paxsenix result beats an LRCLIB line-synced result")
    func combinedModePrioritizesPaxsenix() async {
        let lrclibLyrics = Self.makeSyncedLyrics(source: "LRCLIB", lineText: "Line-only result")
        let paxsenixLyrics = Self.makeWordSyncedLyrics(source: "Paxsenix", lineText: "Word-synced result")
        let service = SyncedLyricsService(providers: [
            MockLyricsProvider(name: "LRCLIB", result: .synced(lrclibLyrics)),
            MockLyricsProvider(name: "Paxsenix", result: .synced(paxsenixLyrics)),
        ])

        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-provider-priority"), forceRefresh: true)

        #expect(service.currentLyrics == .synced(paxsenixLyrics))
        #expect(service.activeProvider == "Paxsenix")
    }

    @Test("fetchLyrics caches results and derives activeProvider from cached source")
    func fetchLyricsCachesResults() async {
        let synced = Self.makeSyncedLyrics(source: "Cached Source", lineText: "Cached line")
        let provider = MockLyricsProvider(name: "MockProvider", result: .synced(synced))
        let service = SyncedLyricsService(providers: [provider])
        let info = Self.makeSearchInfo(videoId: "video-cache")

        await service.fetchLyrics(for: info)

        #expect(await provider.callCount() == 1)
        #expect(service.currentLyrics == .synced(synced))
        #expect(service.activeProvider == "MockProvider")

        await service.fetchLyrics(for: info)

        #expect(await provider.callCount() == 1)
        #expect(service.currentLyrics == .synced(synced))
        #expect(service.activeProvider == "Cached Source")
    }

    @Test("fetchLyrics returns cached unavailable results without refetching")
    func fetchLyricsReturnsCachedUnavailableWithoutRefetching() async {
        let provider = MockLyricsProvider(name: "UnavailableProvider", result: .unavailable)
        let service = SyncedLyricsService(providers: [provider])
        let info = Self.makeSearchInfo(videoId: "video-unavailable")

        await service.fetchLyrics(for: info)

        #expect(service.currentLyrics == .unavailable)
        #expect(service.activeProvider == nil)
        #expect(service.isLoading == false)
        #expect(await provider.callCount() == 1)

        await service.fetchLyrics(for: info)

        #expect(service.currentLyrics == .unavailable)
        #expect(service.activeProvider == nil)
        #expect(await provider.callCount() == 1)
    }

    @Test("fetchLyrics updates loading state while a search is in flight")
    func fetchLyricsUpdatesLoadingState() async {
        let gate = SearchGate()
        let synced = Self.makeSyncedLyrics(source: "Delayed Source", lineText: "Delayed line")
        let provider = MockLyricsProvider(name: "SlowProvider", result: .synced(synced), gate: gate)
        let service = SyncedLyricsService(providers: [provider])
        let info = Self.makeSearchInfo(videoId: "video-loading")

        let task = Task { @MainActor in
            await service.fetchLyrics(for: info)
        }

        await gate.waitUntilStarted()

        #expect(service.isLoading)
        #expect(service.currentLyrics == .unavailable)

        await gate.release()
        await task.value

        #expect(service.isLoading == false)
        #expect(service.currentLyrics == .synced(synced))
        #expect(service.activeProvider == "SlowProvider")
    }

    @Test("concurrent requests for the same video share one provider search")
    func concurrentRequestsShareProviderSearch() async {
        let gate = SearchGate()
        let synced = Self.makeSyncedLyrics(source: "Shared Source", lineText: "Shared line")
        let provider = MockLyricsProvider(name: "SharedProvider", result: .synced(synced), gate: gate)
        let service = SyncedLyricsService(providers: [provider])
        let info = Self.makeSearchInfo(videoId: "video-shared")

        let firstTask = Task { @MainActor in
            await service.fetchLyrics(for: info)
        }
        await gate.waitUntilStarted()

        let secondTask = Task { @MainActor in
            await service.fetchLyrics(for: info)
        }

        await gate.release()
        await firstTask.value
        await secondTask.value

        #expect(await provider.callCount() == 1)
        #expect(service.currentLyrics == .synced(synced))
        #expect(service.currentLyricsVideoId == info.videoId)
        #expect(service.isLoading == false)
    }

    @Test("fetchLyrics can upgrade cached plain lyrics to synced results")
    func fetchLyricsUpgradesCachedPlainLyricsToSyncedResults() async {
        let plain = Lyrics(text: "Fallback lyrics", source: "Lyrics by LyricFind")
        let synced = Self.makeSyncedLyrics(source: "Synced Source", lineText: "Synced line")
        let provider = MockLyricsProvider(
            name: "SyncedProvider",
            result: .synced(synced)
        )
        let service = SyncedLyricsService(providers: [provider])
        let videoId = "video-fallback"

        service.fallbackToPlainLyrics(plain, videoId: videoId)

        #expect(service.currentLyrics == .plain(plain))
        #expect(service.activeProvider == "Lyrics by LyricFind")

        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: videoId), forceRefresh: true)

        #expect(service.currentLyrics == .synced(synced))
        #expect(service.activeProvider == "SyncedProvider")
        #expect(await provider.callCount() == 1)
    }

    @Test("fetchLyrics keeps cached plain lyrics when no synced result is found")
    func fetchLyricsKeepsCachedPlainLyricsWhenProvidersStillFail() async {
        let plain = Lyrics(text: "Fallback lyrics", source: "Lyrics by LyricFind")
        let provider = MockLyricsProvider(name: "UnavailableProvider", result: .unavailable)
        let service = SyncedLyricsService(providers: [provider])
        let videoId = "video-fallback-plain"

        service.fallbackToPlainLyrics(plain, videoId: videoId)

        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: videoId))

        #expect(service.currentLyrics == .plain(plain))
        #expect(service.activeProvider == "Lyrics by LyricFind")
        #expect(await provider.callCount() == 0)
    }

    @Test("fetchLyrics forceRefresh retries after cached unavailable result")
    func fetchLyricsForceRefreshRetriesAfterCachedUnavailableResult() async {
        let provider = MockLyricsProvider(name: "UnavailableProvider", result: .unavailable)
        let service = SyncedLyricsService(providers: [provider])
        let info = Self.makeSearchInfo(videoId: "video-unavailable-refresh")

        await service.fetchLyrics(for: info)
        #expect(await provider.callCount() == 1)

        await service.fetchLyrics(for: info, forceRefresh: true)

        #expect(service.currentLyrics == .unavailable)
        #expect(service.activeProvider == nil)
        #expect(await provider.callCount() == 2)
    }

    @Test("stale in-flight fetches do not overwrite a newer result")
    func staleFetchesDoNotOverwriteNewerResults() async {
        let staleGate = SearchGate()
        let staleLyrics = Self.makeSyncedLyrics(source: "Stale Source", lineText: "Stale line")
        let freshLyrics = Self.makeSyncedLyrics(source: "Fresh Source", lineText: "Fresh line")
        let provider = MockLyricsProvider(name: "RacingProvider") { info in
            if info.videoId == "video-stale" {
                await staleGate.markStarted()
                await staleGate.waitUntilReleased()
                return .synced(staleLyrics)
            }

            return .synced(freshLyrics)
        }
        let service = SyncedLyricsService(providers: [provider])

        let staleTask = Task { @MainActor in
            await service.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-stale"))
        }

        await staleGate.waitUntilStarted()
        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-fresh"))

        #expect(service.currentLyrics == .synced(freshLyrics))
        #expect(service.activeProvider == "RacingProvider")

        await staleGate.release()
        await staleTask.value

        #expect(service.currentLyrics == .synced(freshLyrics))
        #expect(service.activeProvider == "RacingProvider")
        #expect(await provider.callCount() == 2)
    }

    @Test("fallbackToPlainLyrics does not overwrite synced lyrics")
    func fallbackToPlainLyricsDoesNotOverwriteSyncedLyrics() async {
        let synced = Self.makeSyncedLyrics(source: "Primary Synced Source", lineText: "Primary line")
        let service = SyncedLyricsService(providers: [
            MockLyricsProvider(name: "SyncedProvider", result: .synced(synced)),
        ])

        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-keep-synced"))
        service.fallbackToPlainLyrics(
            Lyrics(text: "Fallback lyrics", source: "Lyrics by YouTube Music"),
            videoId: "video-keep-synced"
        )

        #expect(service.currentLyrics == .synced(synced))
        #expect(service.activeProvider == "SyncedProvider")
    }

    @Test("all providers are searched concurrently")
    func allProvidersAreSearchedConcurrently() async {
        let lrclibLyrics = Self.makeSyncedLyrics(source: "LRCLIB", lineText: "Line-only result")
        let paxsenixLyrics = Self.makeWordSyncedLyrics(source: "Paxsenix", lineText: "Word-synced result")
        let lrclib = MockLyricsProvider(name: "LRCLIB", result: .synced(lrclibLyrics))
        let paxsenix = MockLyricsProvider(name: "Paxsenix", result: .synced(paxsenixLyrics))
        let service = SyncedLyricsService(providers: [lrclib, paxsenix])

        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-concurrent"))

        // Both providers are invoked, and the word-synced result wins.
        #expect(await lrclib.callCount() == 1)
        #expect(await paxsenix.callCount() == 1)
        #expect(service.currentLyrics == .synced(paxsenixLyrics))
        #expect(service.activeProvider == "Paxsenix")
    }

    @Test("combined mode falls back to LRCLIB when Paxsenix has no result")
    func paxsenixUnavailableFallsBackToLRCLIB() async {
        let lrclibLyrics = Self.makeSyncedLyrics(source: "LRCLIB", lineText: "Line-only result")
        let paxsenix = MockLyricsProvider(name: "Paxsenix", result: .unavailable)
        let lrclib = MockLyricsProvider(name: "LRCLIB", result: .synced(lrclibLyrics))
        let service = SyncedLyricsService(providers: [paxsenix, lrclib])

        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-fallback-lrclib"))

        #expect(service.currentLyrics == .synced(lrclibLyrics))
        #expect(service.activeProvider == "LRCLIB")
        #expect(await paxsenix.callCount() == 1)
        #expect(await lrclib.callCount() == 1)
    }

    @Test("a word-synced result replaces an earlier line-synced result, shows the shimmer, and is cached")
    func wordSyncedResultReplacesEarlierLineResult() async throws {
        let previous = SettingsManager.shared.lyricsProvider
        SettingsManager.shared.lyricsProvider = .paxsenixAndLRCLib
        defer { SettingsManager.shared.lyricsProvider = previous }

        let dir = try FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncedLyricsReplacementTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LyricsCacheStore(directory: dir, legacyFileURL: dir.appendingPathComponent("legacy.json"))
        let gate = SearchGate()
        let lrclibLyrics = Self.makeSyncedLyrics(source: "LRCLIB", lineText: "Line-only result")
        let paxsenixLyrics = Self.makeWordSyncedLyrics(source: "Paxsenix", lineText: "Word-synced result")
        let lrclib = MockLyricsProvider(name: "LRCLIB", result: .synced(lrclibLyrics))
        let paxsenix = MockLyricsProvider(name: "Paxsenix", result: .synced(paxsenixLyrics), gate: gate)
        let service = SyncedLyricsService(providers: [lrclib, paxsenix], cacheStore: store)
        let info = Self.makeSearchInfo(videoId: "video-replacement")

        let task = Task { @MainActor in
            await service.fetchLyrics(for: info)
        }

        // LRCLIB resolves first while Paxsenix is still pending: its line
        // result is displayed immediately and the shimmer appears.
        await gate.waitUntilStarted()
        while !service.currentLyrics.isAvailable { await Task.yield() }

        #expect(service.currentLyrics == .synced(lrclibLyrics))
        #expect(service.activeProvider == "LRCLIB")
        #expect(service.isLoading == false)
        #expect(service.searchingForBetterLyrics)

        // Paxsenix's word-synced result replaces the line-synced one.
        await gate.release()
        await task.value

        #expect(service.currentLyrics == .synced(paxsenixLyrics))
        #expect(service.activeProvider == "Paxsenix")
        #expect(service.searchingForBetterLyrics == false)
        #expect(await lrclib.callCount() == 1)
        #expect(await paxsenix.callCount() == 1)

        // The better result is what future plays read from the cache.
        #expect(store.load(for: "video-replacement") == .synced(paxsenixLyrics))
    }

    @Test("word-synced Paxsenix beats both line-synced KuGo and LRCLIB results")
    func wordSyncedBeatsTwoLineProviders() async {
        let lrclibLyrics = Self.makeSyncedLyrics(source: "LRCLIB", lineText: "LRCLIB line")
        let kugouLyrics = Self.makeSyncedLyrics(source: "KuGo", lineText: "KuGo line")
        let paxsenixLyrics = Self.makeWordSyncedLyrics(source: "Paxsenix", lineText: "Word line")
        let lrclib = MockLyricsProvider(name: "LRCLIB", result: .synced(lrclibLyrics))
        let kugou = MockLyricsProvider(name: "KuGo", result: .synced(kugouLyrics))
        let paxsenix = MockLyricsProvider(name: "Paxsenix", result: .synced(paxsenixLyrics))
        let service = SyncedLyricsService(providers: [lrclib, kugou, paxsenix])

        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-three-provider"))

        // All three are searched concurrently; the word-synced result wins.
        #expect(await lrclib.callCount() == 1)
        #expect(await kugou.callCount() == 1)
        #expect(await paxsenix.callCount() == 1)
        #expect(service.currentLyrics == .synced(paxsenixLyrics))
        #expect(service.activeProvider == "Paxsenix")
        #expect(service.searchingForBetterLyrics == false)
    }

    @Test("a single provider never shows the still-searching shimmer")
    func singleProviderHasNoShimmer() async {
        let synced = Self.makeSyncedLyrics(source: "Only Source", lineText: "Only line")
        let service = SyncedLyricsService(providers: [
            MockLyricsProvider(name: "OnlyProvider", result: .synced(synced)),
        ])

        await service.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-single"))

        #expect(service.currentLyrics == .synced(synced))
        #expect(service.searchingForBetterLyrics == false)
    }

    @Test("opening another view for the same track does not re-search an LRCLIB result")
    func loadedLRCLIBResultIsNotResearched() async {
        let previous = SettingsManager.shared.lyricsProvider
        SettingsManager.shared.lyricsProvider = .paxsenixAndLRCLib
        defer { SettingsManager.shared.lyricsProvider = previous }

        let lrclibLyrics = Self.makeSyncedLyrics(source: "LRCLIB", lineText: "Line-only result")
        let paxsenixLyrics = Self.makeWordSyncedLyrics(source: "Paxsenix", lineText: "Word-synced result")
        let paxsenixState = LyricResultBox(.unavailable)
        let paxsenix = MockLyricsProvider(name: "Paxsenix") { _ in
            await paxsenixState.get()
        }
        let lrclib = MockLyricsProvider(name: "LRCLIB", result: .synced(lrclibLyrics))
        let service = SyncedLyricsService(providers: [paxsenix, lrclib])
        let info = Self.makeSearchInfo(videoId: "video-panel-reopen")

        // Sidebar loads lyrics: Paxsenix has nothing, LRCLIB supplies them.
        await service.fetchLyrics(for: info)
        #expect(service.currentLyrics == .synced(lrclibLyrics))
        #expect(service.activeProvider == "LRCLIB")

        // Paxsenix would now succeed, but opening the fullscreen view must
        // not trigger a search — the already-loaded result is served as-is.
        await paxsenixState.set(.synced(paxsenixLyrics))
        await service.fetchLyrics(for: info)

        #expect(service.currentLyrics == .synced(lrclibLyrics))
        #expect(service.activeProvider == "LRCLIB")
        #expect(await paxsenix.callCount() == 1)
        #expect(await lrclib.callCount() == 1)

        // The explicit refresh path still upgrades to Paxsenix word-sync.
        await service.fetchLyrics(for: info, forceRefresh: true)

        #expect(service.currentLyrics == .synced(paxsenixLyrics))
        #expect(service.activeProvider == "Paxsenix")
        #expect(await paxsenix.callCount() == 2)
    }

    @Test("combined mode serves a cached LRCLIB result from disk without re-searching")
    func combinedModeServesCachedLRCLIBResultFromDisk() async throws {
        let previous = SettingsManager.shared.lyricsProvider
        SettingsManager.shared.lyricsProvider = .paxsenixAndLRCLib
        defer { SettingsManager.shared.lyricsProvider = previous }

        let dir = try FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncedLyricsCombinedCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = LyricsCacheStore(directory: dir, legacyFileURL: dir.appendingPathComponent("legacy.json"))
        let lrclibLyrics = Self.makeSyncedLyrics(source: "LRCLIB", lineText: "Line-only result")

        // First service: Paxsenix empty, LRCLIB supplies lyrics. Persisted to disk.
        let firstPaxsenix = MockLyricsProvider(name: "Paxsenix", result: .unavailable)
        let firstLRCLIB = MockLyricsProvider(name: "LRCLIB", result: .synced(lrclibLyrics))
        let first = SyncedLyricsService(providers: [firstPaxsenix, firstLRCLIB], cacheStore: store)
        await first.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-disk-cache"))
        #expect(first.currentLyrics == .synced(lrclibLyrics))
        #expect(store.load(for: "video-disk-cache") != nil)

        // A fresh service backed by the same disk cache must serve the LRCLIB
        // record without calling any provider, even in combined mode.
        let secondPaxsenix = MockLyricsProvider(name: "Paxsenix", result: .synced(lrclibLyrics))
        let secondLRCLIB = MockLyricsProvider(name: "LRCLIB", result: .synced(lrclibLyrics))
        let second = SyncedLyricsService(providers: [secondPaxsenix, secondLRCLIB], cacheStore: store)
        await second.fetchLyrics(for: Self.makeSearchInfo(videoId: "video-disk-cache"))

        #expect(second.currentLyrics == .synced(lrclibLyrics))
        #expect(second.activeProvider == "LRCLIB")
        #expect(await secondPaxsenix.callCount() == 0)
        #expect(await secondLRCLIB.callCount() == 0)
    }

    @Test("LRCLIB-only mode serves a cached LRCLIB result without refetching")
    func lrclibOnlyModeServesCachedResult() async {
        let previous = SettingsManager.shared.lyricsProvider
        SettingsManager.shared.lyricsProvider = .lrclib
        defer { SettingsManager.shared.lyricsProvider = previous }

        let lrclibLyrics = Self.makeSyncedLyrics(source: "LRCLIB", lineText: "Line-only result")
        let provider = MockLyricsProvider(name: "LRCLIB", result: .synced(lrclibLyrics))
        let service = SyncedLyricsService(providers: [provider])
        let info = Self.makeSearchInfo(videoId: "video-lrclib-only")

        await service.fetchLyrics(for: info)
        #expect(service.currentLyrics == .synced(lrclibLyrics))

        await service.fetchLyrics(for: info)
        #expect(service.currentLyrics == .synced(lrclibLyrics))
        #expect(await provider.callCount() == 1)
    }

    @Test("forceRefresh refetches even when an available result is cached")
    func forceRefreshRefetchesCachedAvailableResult() async {
        let first = Self.makeSyncedLyrics(source: "First Source", lineText: "First line")
        let second = Self.makeSyncedLyrics(source: "Second Source", lineText: "Second line")
        let state = LyricResultBox(.synced(first))
        let provider = MockLyricsProvider(name: "StatefulProvider") { _ in
            await state.get()
        }
        let service = SyncedLyricsService(providers: [provider])
        let info = Self.makeSearchInfo(videoId: "video-force-refresh")

        await service.fetchLyrics(for: info)
        #expect(service.currentLyrics == .synced(first))
        #expect(await provider.callCount() == 1)

        await state.set(.synced(second))
        await service.fetchLyrics(for: info, forceRefresh: true)

        #expect(service.currentLyrics == .synced(second))
        #expect(await provider.callCount() == 2)
    }

    @Test("forceRefresh resets the displayed result like a fresh load")
    func forceRefreshResetsDisplayedResultLikeFreshLoad() async {
        let first = Self.makeSyncedLyrics(source: "First Source", lineText: "First line")
        let second = Self.makeSyncedLyrics(source: "Second Source", lineText: "Second line")
        let gate = SearchGate()
        let gateSwitch = GateSwitch()
        let state = LyricResultBox(.synced(first))
        let provider = MockLyricsProvider(name: "StatefulProvider") { _ in
            await gate.markStarted()
            if await gateSwitch.isEnabled() {
                await gate.waitUntilReleased()
            }
            return await state.get()
        }
        let service = SyncedLyricsService(providers: [provider])
        let info = Self.makeSearchInfo(videoId: "video-refresh-reset")

        // The first fetch is not gated; only the refresh below is held so the
        // mid-flight state can be asserted deterministically.
        await service.fetchLyrics(for: info)
        #expect(service.currentLyrics == .synced(first))

        // Refreshing behaves exactly like opening the panel on a new song:
        // the old result is cleared while the concurrent search is in flight,
        // so the first-arrival + shimmer + swap-in flow can play out again.
        await gateSwitch.enable()
        await state.set(.synced(second))
        let task = Task { @MainActor in
            await service.fetchLyrics(for: info, forceRefresh: true)
        }
        await gate.waitUntilStarted()

        #expect(service.isLoading)
        #expect(service.currentLyrics == .unavailable)
        #expect(service.currentLyricsVideoId == nil)

        await gate.release()
        await task.value

        #expect(service.currentLyrics == .synced(second))
        #expect(await provider.callCount() == 2)
    }

    @Test("clearCache(keepCurrent: false) resets state and forces a refetch")
    func clearCacheResetsState() async {
        let synced = Self.makeSyncedLyrics(source: "Clear Source", lineText: "Clear line")
        let provider = MockLyricsProvider(name: "ClearProvider", result: .synced(synced))
        let service = SyncedLyricsService(providers: [provider])
        let info = Self.makeSearchInfo(videoId: "video-clear")

        await service.fetchLyrics(for: info)
        #expect(service.currentLyrics == .synced(synced))

        service.clearCache(keepCurrent: false)

        #expect(service.currentLyrics == .unavailable)
        #expect(service.currentLyricsVideoId == nil)
        #expect(service.activeProvider == nil)
        #expect(service.isLoading == false)

        await service.fetchLyrics(for: info)
        #expect(service.currentLyrics == .synced(synced))
        #expect(await provider.callCount() == 2)
    }

    private static func makeSearchInfo(videoId: String) -> LyricsSearchInfo {
        LyricsSearchInfo(
            title: "Test Song",
            artist: "Test Artist",
            album: "Test Album",
            duration: 180,
            videoId: videoId
        )
    }

    private static func makeSyncedLyrics(source: String, lineText: String) -> SyncedLyrics {
        SyncedLyrics(
            lines: [
                SyncedLyricLine(timeInMs: 0, duration: 5000, text: lineText, words: nil),
            ],
            source: source
        )
    }

    private static func makeWordSyncedLyrics(source: String, lineText: String) -> SyncedLyrics {
        SyncedLyrics(
            lines: [
                SyncedLyricLine(
                    timeInMs: 0,
                    duration: 5000,
                    text: lineText,
                    words: [TimedWord(timeInMs: 0, word: "Word")]
                ),
            ],
            source: source
        )
    }
}

// MARK: - MockLyricsProvider

private final class MockLyricsProvider: LyricsProvider, @unchecked Sendable {
    let name: String
    let capability: LyricsCapability

    private let searchHandler: (LyricsSearchInfo) async -> LyricResult
    private let counter = SearchCounter()

    init(name: String, result: LyricResult, capability: LyricsCapability? = nil, gate: SearchGate? = nil) {
        self.name = name
        self.capability = capability ?? result.capability
        self.searchHandler = { _ in
            if let gate {
                await gate.markStarted()
                await gate.waitUntilReleased()
            }

            return result
        }
    }

    init(name: String, capability: LyricsCapability = .word, searchHandler: @escaping (LyricsSearchInfo) async -> LyricResult) {
        self.name = name
        self.capability = capability
        self.searchHandler = searchHandler
    }

    func search(info: LyricsSearchInfo) async -> LyricResult {
        await self.counter.increment()
        return await self.searchHandler(info)
    }

    func callCount() async -> Int {
        await self.counter.value()
    }
}

// MARK: - SearchCounter

private actor SearchCounter {
    private var count = 0

    func increment() {
        self.count += 1
    }

    func value() -> Int {
        self.count
    }
}

// MARK: - SearchGate

private actor SearchGate {
    private var didStart = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        guard !self.didStart else { return }

        self.didStart = true
        let waiters = self.startWaiters
        self.startWaiters.removeAll()

        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilStarted() async {
        if self.didStart {
            return
        }

        await withCheckedContinuation { continuation in
            self.startWaiters.append(continuation)
        }
    }

    func waitUntilReleased() async {
        if self.isReleased {
            return
        }

        await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    func release() {
        guard !self.isReleased else { return }

        self.isReleased = true
        let waiters = self.releaseWaiters
        self.releaseWaiters.removeAll()

        for waiter in waiters {
            waiter.resume()
        }
    }
}

// MARK: - GateSwitch

/// Lets a provider mock gate only some of its invocations. The gate's
/// `markStarted` is always called so tests can wait for the search to begin;
/// `waitUntilReleased` only blocks while the switch is enabled.
private actor GateSwitch {
    private var enabled = false

    func enable() {
        self.enabled = true
    }

    func isEnabled() -> Bool {
        self.enabled
    }
}

// MARK: - LyricResultBox

/// Mutable `LyricResult` storage shared with a provider mock so a test can
/// change what a provider returns between fetches.
private actor LyricResultBox {
    private var stored: LyricResult

    init(_ result: LyricResult) {
        self.stored = result
    }

    func set(_ result: LyricResult) {
        self.stored = result
    }

    func get() -> LyricResult {
        self.stored
    }
}
