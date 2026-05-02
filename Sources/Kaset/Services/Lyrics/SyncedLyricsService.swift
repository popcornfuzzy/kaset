import Foundation

@MainActor
@Observable
final class SyncedLyricsService {
    private struct PersistedCache: Codable {
        let version: Int
        let entries: [String: LyricResult]
    }

    private static let cacheVersion = 1
    private static let cacheFileName = "lyrics-cache.json"

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

    private let cacheFileURL: URL
    private let skipPersistence: Bool
    private var saveTask: Task<Void, Never>?
    private let logger = DiagnosticsLogger.app

    /// In-memory cache keyed by videoId.
    private var cache: [String: LyricResult] = [:]

    /// Monotonic identifier used to ignore stale in-flight searches.
    private var fetchGeneration = 0

    init(providers: [LyricsProvider] = [LRCLibProvider()]) {
        self.providers = providers
        self.cacheFileURL = Self.makeCacheFileURL()
        self.skipPersistence = UITestConfig.isUITestMode || UITestConfig.isRunningUnitTests

        if !self.skipPersistence {
            self.loadCacheFromDisk()
        }
    }

    func clearCache(keepCurrent: Bool = true) {
        self.cache.removeAll()
        if !keepCurrent {
            self.currentLyrics = .unavailable
            self.activeProvider = nil
            self.currentLyricsVideoId = nil
        }
        self.scheduleCacheSave()
    }

    func isCachedUnavailable(for videoId: String) -> Bool {
        if case .unavailable? = self.cache[videoId] {
            return true
        }
        return false
    }

    func fetchLyrics(for info: LyricsSearchInfo, forceRefresh: Bool = false) async {
        self.fetchGeneration += 1
        let requestID = self.fetchGeneration
        let cached = forceRefresh ? nil : self.cache[info.videoId]

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
            self.cache[videoId] = .plain(lyrics)
        } else {
            self.currentLyrics = .unavailable
            self.activeProvider = nil
            self.currentLyricsVideoId = videoId
            self.cache[videoId] = .unavailable
        }

        self.scheduleCacheSave()
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
                self.cache[videoId] = best.result
                self.scheduleCacheSave()
                return .init(result: best.result, activeProvider: best.provider)
            case .plain:
                if case let .plain(cachedPlain)? = cached {
                    return .init(result: .plain(cachedPlain), activeProvider: cachedPlain.source)
                }

                self.cache[videoId] = best.result
                self.scheduleCacheSave()
                return .init(result: best.result, activeProvider: best.provider)
            case .unavailable:
                break
            }
        }

        if case let .plain(cachedPlain)? = cached {
            return .init(result: .plain(cachedPlain), activeProvider: cachedPlain.source)
        }

        self.cache[videoId] = .unavailable
        self.scheduleCacheSave()
        return .init(result: .unavailable, activeProvider: nil)
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

    private static func makeCacheFileURL() -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let appDirectory = (base ?? fileManager.temporaryDirectory)
            .appendingPathComponent("Kaset", isDirectory: true)
        try? fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        return appDirectory.appendingPathComponent(Self.cacheFileName)
    }

    private func loadCacheFromDisk() {
        do {
            guard FileManager.default.fileExists(atPath: self.cacheFileURL.path) else { return }
            let data = try Data(contentsOf: self.cacheFileURL)
            let decoded = try JSONDecoder().decode(PersistedCache.self, from: data)
            guard decoded.version == Self.cacheVersion else {
                self.logger.info("Lyrics cache version mismatch, ignoring persisted cache")
                return
            }
            self.cache = decoded.entries
            self.logger.info("Loaded lyrics cache entries: \(decoded.entries.count)")
        } catch {
            self.logger.error("Failed to load lyrics cache: \(error.localizedDescription)")
        }
    }

    private func scheduleCacheSave() {
        guard !self.skipPersistence else { return }

        self.saveTask?.cancel()
        let snapshot = self.cache
        let url = self.cacheFileURL
        let version = Self.cacheVersion

        self.saveTask = Task.detached(priority: .utility) { [snapshot, url] in
            if snapshot.isEmpty {
                try? FileManager.default.removeItem(at: url)
                return
            }

            do {
                let payload = PersistedCache(version: version, entries: snapshot)
                let data = try JSONEncoder().encode(payload)
                try data.write(to: url, options: [.atomic])
            } catch {
                DiagnosticsLogger.app.error("Failed to save lyrics cache: \(error.localizedDescription)")
            }
        }
    }
}
