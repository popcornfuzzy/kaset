import Foundation

@MainActor
@Observable
final class SyncedLyricsService {
    var currentLyrics: LyricResult = .unavailable
    var activeProvider: String?
    var currentLyricsVideoId: String?
    var isLoading = false
    var errorMessage: String?

    private var providers: [LyricsProvider]
    private var cache: [String: LyricResult] = [:]
    private let cacheStore: LyricsCacheStore?
    private var fetchGeneration = 0

    init(providers: [LyricsProvider]? = nil, cacheStore: LyricsCacheStore? = nil) {
        self.providers = providers ?? Self.providersForCurrentSettings()
        self.cacheStore = cacheStore
    }

    private static func providersForCurrentSettings() -> [LyricsProvider] {
        switch SettingsManager.shared.lyricsProvider {
        case .musixmatchAndLRCLib:
            [MusixmatchProvider(), LRCLibProvider()]
        case .lrclib:
            [LRCLibProvider()]
        }
    }

    func reloadProviderFromSettings() {
        self.providers = Self.providersForCurrentSettings()
        self.fetchGeneration += 1
        self.cache.removeAll()
        self.cacheStore?.removeAll(except: nil)
        self.currentLyrics = .unavailable
        self.activeProvider = nil
        self.currentLyricsVideoId = nil
        self.errorMessage = nil
    }

    func clearCache(keepCurrent: Bool = true) {
        self.cache.removeAll()
        self.errorMessage = nil
        self.cacheStore?.removeAll(except: keepCurrent ? self.currentLyricsVideoId : nil)
        if !keepCurrent {
            self.currentLyrics = .unavailable
            self.activeProvider = nil
            self.currentLyricsVideoId = nil
        }
    }

    func fetchLyrics(for info: LyricsSearchInfo, forceRefresh: Bool = false) async {
        self.fetchGeneration += 1
        let requestID = self.fetchGeneration
        let combinedMode = SettingsManager.shared.lyricsProvider == .musixmatchAndLRCLib
        let cached = forceRefresh ? nil : self.cachedResult(for: info.videoId, combinedMode: combinedMode)

        if let cached {
            self.apply(cached, provider: Self.source(of: cached), videoId: info.videoId, requestID: requestID)
            return
        }

        self.isLoading = true
        self.errorMessage = nil
        if forceRefresh {
            self.cache.removeValue(forKey: info.videoId)
            self.cacheStore?.remove(for: info.videoId)
        }

        var result: LyricResult = .unavailable
        var providerName: String?
        for provider in self.providers {
            let candidate = await provider.search(info: info)
            if candidate.isAvailable {
                result = candidate
                providerName = provider.name
                break
            }
        }

        guard requestID == self.fetchGeneration else { return }
        if !result.isAvailable {
            self.errorMessage = "No lyrics were found from the selected sources."
        }
        self.store(result, for: info.videoId)
        self.apply(result, provider: providerName, videoId: info.videoId, requestID: requestID)
    }

    private func cachedResult(for videoId: String, combinedMode: Bool) -> LyricResult? {
        let result = self.cache[videoId] ?? self.cacheStore?.load(for: videoId)
        guard let result else { return nil }
        if combinedMode, case let .synced(lyrics) = result,
           lyrics.source.caseInsensitiveCompare("LRCLIB") == .orderedSame {
            return nil
        }
        self.cache[videoId] = result
        return result
    }

    func fallbackToPlainLyrics(_ lyrics: Lyrics, videoId: String) {
        guard !self.currentLyrics.isAvailable || self.currentLyricsVideoId != videoId else { return }
        let result: LyricResult = lyrics.isAvailable ? .plain(lyrics) : .unavailable
        self.store(result, for: videoId)
        self.apply(result, provider: lyrics.source, videoId: videoId, requestID: self.fetchGeneration)
    }

    private func store(_ result: LyricResult, for videoId: String) {
        self.cache[videoId] = result
        self.cacheStore?.save(result, for: videoId)
    }

    private func apply(_ result: LyricResult, provider: String?, videoId: String, requestID: Int) {
        guard requestID == self.fetchGeneration else { return }
        self.currentLyrics = result
        self.activeProvider = provider ?? Self.source(of: result)
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
