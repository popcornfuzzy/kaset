import Foundation

@MainActor
@Observable
final class SyncedLyricsService {
    private struct ResolvedLyrics {
        let result: LyricResult
        let activeProvider: String?
    }

    /// Current lyrics result.
    var currentLyrics: LyricResult = .unavailable

    /// Which provider supplied the current lyrics.
    var activeProvider: String?

    /// Video ID for which `currentLyrics` is valid.
    var currentLyricsVideoId: String?

    /// Loading state.
    var isLoading = false

    /// All registered providers, ordered by priority.
    private let providers: [LyricsProvider]

    /// In-memory cache keyed by videoId.
    private var cache: [String: LyricResult] = [:]

    /// Optional persistent cache that stores one file per song.
    /// When `nil`, the service only caches in memory (used by unit tests).
    private let cacheStore: LyricsCacheStore?

    /// Monotonic identifier used to ignore stale in-flight searches.
    private var fetchGeneration = 0

    init(
        providers: [LyricsProvider] = [LRCLibProvider()],
        cacheStore: LyricsCacheStore? = nil
    ) {
        self.providers = providers
        self.cacheStore = cacheStore
    }

    func clearCache(keepCurrent: Bool = true) {
        self.cache.removeAll()
        self.cacheStore?.removeAll(except: keepCurrent ? self.currentLyricsVideoId : nil)
        if !keepCurrent {
            self.currentLyrics = .unavailable
            self.activeProvider = nil
            self.currentLyricsVideoId = nil
        }
    }

    func isCachedUnavailable(for videoId: String) -> Bool {
        if case .unavailable? = self.cache[videoId] {
            return true
        }

        if case .unavailable? = self.cacheStore?.load(for: videoId) {
            self.cache[videoId] = .unavailable
            return true
        }
        return false
    }

    func fetchLyrics(for info: LyricsSearchInfo, forceRefresh: Bool = false) async {
        self.fetchGeneration += 1
        let requestID = self.fetchGeneration
        var cached: LyricResult?

        if !forceRefresh {
            cached = self.cache[info.videoId] ?? self.cacheStore?.load(for: info.videoId)
            if let cached {
                self.cache[info.videoId] = cached
            }
        }

        if let cached {
            self.applyResolvedLyrics(
                .init(
                    result: cached,
                    activeProvider: Self.cachedProviderName(for: cached)
                ),
                requestID: requestID,
                videoId: info.videoId
            )
            return
        }

        self.isLoading = true

        // Don't clear currentLyrics immediately to prevent flicker, but reset state when done
        var allResults: [(provider: String, result: LyricResult)] = []

        // Fetch concurrently
        await withTaskGroup(of: (String, LyricResult)?.self) { group in
            for provider in self.providers {
                group.addTask {
                    let result = await provider.search(info: info)
                    return (provider.name, result)
                }
            }

            for await res in group {
                if let res {
                    allResults.append(res)
                }
            }
        }

        // Pick best result
        // Score: Synced = 2, Plain = 1, YTMusic = +1 bias
        let best = allResults.max { a, b in
            let scoreA = self.score(result: a.result, providerName: a.provider)
            let scoreB = self.score(result: b.result, providerName: b.provider)
            return scoreA < scoreB
        }

        let resolved = self.resolveLyrics(best: best, cached: cached, videoId: info.videoId)
        self.applyResolvedLyrics(resolved, requestID: requestID, videoId: info.videoId)
    }

    /// Fallback logic
    func fallbackToPlainLyrics(_ lyrics: Lyrics, videoId: String) {
        if case .synced = self.currentLyrics, self.currentLyricsVideoId == videoId {
            // Already synced, don't overwrite with plain
            return
        }

        if lyrics.isAvailable {
            self.currentLyrics = .plain(lyrics)
            self.activeProvider = lyrics.source
            self.currentLyricsVideoId = videoId
            self.storeInCache(.plain(lyrics), for: videoId)
        } else {
            self.currentLyrics = .unavailable
            self.activeProvider = nil
            self.currentLyricsVideoId = videoId
            self.storeInCache(.unavailable, for: videoId)
        }
    }

    private func score(result: LyricResult, providerName: String) -> Int {
        var s = 0
        switch result {
        case .synced: s += 2
        case .plain: s += 1
        case .unavailable: return -1 // Disqualified
        }

        if providerName == "YTMusic" {
            s += 1
        }
        return s
    }

    private func resolveLyrics(
        best: (provider: String, result: LyricResult)?,
        cached: LyricResult?,
        videoId: String
    ) -> ResolvedLyrics {
        if let best {
            switch best.result {
            case .synced:
                self.storeInCache(best.result, for: videoId)
                return .init(result: best.result, activeProvider: best.provider)
            case .plain:
                if case let .plain(cachedPlain)? = cached {
                    return .init(result: .plain(cachedPlain), activeProvider: cachedPlain.source)
                }

                self.storeInCache(best.result, for: videoId)
                return .init(result: best.result, activeProvider: best.provider)
            case .unavailable:
                break
            }
        }

        if case let .plain(cachedPlain)? = cached {
            return .init(result: .plain(cachedPlain), activeProvider: cachedPlain.source)
        }

        self.storeInCache(.unavailable, for: videoId)
        return .init(result: .unavailable, activeProvider: nil)
    }

    /// Stores a result in memory and, when enabled, in the per-song file cache.
    private func storeInCache(_ result: LyricResult, for videoId: String) {
        self.cache[videoId] = result
        self.cacheStore?.save(result, for: videoId)
    }

    /// Splits a legacy single-file lyrics cache into per-song files.
    /// Runs the disk work off the main actor so it stays in the background.
    func migrateLegacyCacheIfNeeded() async {
        guard let cacheStore else { return }

        _ = await Task.detached(priority: .utility) {
            cacheStore.migrateLegacyCacheIfNeeded()
        }.value
    }

    private func applyResolvedLyrics(_ resolved: ResolvedLyrics, requestID: Int, videoId: String) {
        guard requestID == self.fetchGeneration else { return }

        self.currentLyrics = resolved.result
        self.activeProvider = resolved.activeProvider
        self.currentLyricsVideoId = videoId
        self.isLoading = false
    }

    private static func cachedProviderName(for result: LyricResult) -> String? {
        switch result {
        case let .synced(lyrics):
            lyrics.source
        case let .plain(lyrics):
            lyrics.source
        case .unavailable:
            nil
        }
    }
}
