import Foundation
import Observation

/// Resolves animated album canvas videos for the fullscreen now-playing view.
///
/// The still album artwork always renders first; this service looks up an
/// animated canvas in the background and exposes a ready-to-play URL so the
/// view can crossfade it in. Lookups are cached per track (memory + disk), and
/// direct video files (MP4s) are downloaded once and replayed from disk.
@MainActor
@Observable
final class CanvasService {
    /// Canvas resolved for the current track, if one exists.
    private(set) var currentCanvas: CanvasArtwork?

    /// Playback URL for `currentCanvas` — a local file when the video has been
    /// downloaded, otherwise the remote URL.
    private(set) var currentCanvasURL: URL?

    /// Video ID the current canvas state belongs to. The fullscreen view uses
    /// this to hide stale canvases when the track changes.
    private(set) var currentCanvasVideoId: String?

    /// Whether a canvas lookup is currently in flight for the current track.
    private(set) var isLoadingCanvas = false

    /// Provider that supplied the current canvas.
    private(set) var activeProvider: String?

    private let providers: [any CanvasProvider]
    private let lookupCache: CanvasCache
    private let videoFileCache: CanvasVideoFileCache
    private var fetchGeneration = 0

    init(
        providers: [any CanvasProvider]? = nil,
        lookupCache: CanvasCache = .shared,
        videoFileCache: CanvasVideoFileCache = .shared
    ) {
        self.providers = providers ?? [TidalCanvasProvider(), AppleMusicCanvasProvider()]
        self.lookupCache = lookupCache
        self.videoFileCache = videoFileCache
    }

    // MARK: - Lookup

    /// Looks up an animated canvas for the given track and prepares it for
    /// playback. No-op when animated canvases are disabled in Settings.
    func loadCanvas(for info: CanvasSearchInfo) async {
        guard SettingsManager.shared.animatedCanvasEnabled else {
            self.resetState()
            return
        }
        guard !info.videoId.isEmpty else { return }

        self.fetchGeneration += 1
        let requestID = self.fetchGeneration

        // Serve a cached lookup (including cached misses) without re-searching.
        if let cached = await self.lookupCache.cachedLookup(for: info.videoId) {
            switch cached {
            case .found:
                DiagnosticsLogger.ui.debug("Canvas cache HIT (found) for videoId \(info.videoId, privacy: .public)")
            case .notFound:
                DiagnosticsLogger.ui.debug("Canvas cache HIT (notFound) for videoId \(info.videoId, privacy: .public)")
            }
            await self.apply(cached, videoId: info.videoId, requestID: requestID)
            return
        }

        self.isLoadingCanvas = true
        self.activeProvider = nil
        DiagnosticsLogger.ui.debug("Canvas lookup started (cache MISS) for videoId \(info.videoId, privacy: .public), title \(info.title, privacy: .public), artist \(info.artist, privacy: .public), album \(info.album ?? "nil", privacy: .public)")

        let result = await Self.searchProviders(providers: self.providers, info: info)
        await self.lookupCache.storeLookup(result, for: info.videoId)

        guard requestID == self.fetchGeneration else { return }
        await self.apply(result, videoId: info.videoId, requestID: requestID)
    }

    /// Clears the lookup cache, downloaded video files, and any in-memory
    /// canvas state.
    func clearCache() async {
        self.fetchGeneration += 1
        await self.lookupCache.clear()
        await self.videoFileCache.clear()
        self.resetState()
    }

    /// Total on-disk size of the lookup + video caches in bytes.
    func diskCacheSize() async -> Int64 {
        let lookupSize = await self.lookupCache.diskCacheSize()
        let videoSize = await self.videoFileCache.diskCacheSize()
        return lookupSize + videoSize
    }

    private func resetState() {
        self.currentCanvas = nil
        self.currentCanvasURL = nil
        self.currentCanvasVideoId = nil
        self.isLoadingCanvas = false
        self.activeProvider = nil
    }

    private func apply(_ result: CanvasCache.LookupResult, videoId: String, requestID: Int) async {
        self.isLoadingCanvas = false
        switch result {
        case let .found(artwork):
            // Resolve a local playback URL before exposing the canvas so the
            // crossfade never waits on the network. Falls back to streaming.
            let playbackURL: URL?
            if artwork.isHLS {
                playbackURL = artwork.videoURL
            } else {
                playbackURL = await self.videoFileCache.ensureLocalFile(for: artwork.videoURL) ?? artwork.videoURL
            }
            guard requestID == self.fetchGeneration else { return }
            self.currentCanvas = artwork
            self.currentCanvasURL = playbackURL
            self.currentCanvasVideoId = videoId
            self.activeProvider = artwork.source
            DiagnosticsLogger.ui.info(
                "Canvas resolved (\(artwork.source)): \(artwork.videoURL.absoluteString) → \(playbackURL?.absoluteString ?? "nil")"
            )
        case .notFound:
            guard requestID == self.fetchGeneration else { return }
            self.currentCanvas = nil
            self.currentCanvasURL = nil
            self.currentCanvasVideoId = videoId
            self.activeProvider = nil
            DiagnosticsLogger.ui.debug("No canvas found for videoId \(videoId)")
        }
    }

    /// Runs all providers concurrently; the first valid canvas wins immediately.
    ///
    /// Note: this must NOT use `withTaskGroup` with an early return — task
    /// groups wait for every child task to finish before returning, so a slow
    /// provider would delay a fast provider's result by its full runtime.
    @MainActor
    private static func searchProviders(
        providers: [any CanvasProvider],
        info: CanvasSearchInfo
    ) async -> CanvasCache.LookupResult {
        guard !providers.isEmpty else { return .notFound }

        let race = FirstCanvasWins(pendingCount: providers.count)
        let tasks = providers.map { provider in
            Task {
                let artwork = await provider.fetchCanvas(for: info)
                if let artwork {
                    DiagnosticsLogger.ui.debug(
                        "Canvas provider \(provider.name, privacy: .public) FOUND a canvas for \(info.videoId, privacy: .public): \(artwork.videoURL.absoluteString, privacy: .public)"
                    )
                } else {
                    DiagnosticsLogger.ui.debug(
                        "Canvas provider \(provider.name, privacy: .public) returned nothing for \(info.videoId, privacy: .public)"
                    )
                }
                await race.submit(artwork)
            }
        }

        let winner = await race.value()

        // Cancel stragglers without awaiting them (they may be mid-request).
        for task in tasks {
            task.cancel()
        }

        if let winner {
            return .found(winner)
        }
        return .notFound
    }
}

/// Delivers the first non-nil canvas across a set of provider tasks without
/// waiting for the remaining tasks to complete.
private actor FirstCanvasWins {
    private var winner: CanvasArtwork?
    private var pendingCount: Int
    private var isFinished = false
    private var waiters: [CheckedContinuation<CanvasArtwork?, Never>] = []

    init(pendingCount: Int) {
        self.pendingCount = max(0, pendingCount)
        if self.pendingCount == 0 {
            self.isFinished = true
        }
    }

    func submit(_ artwork: CanvasArtwork?) {
        guard !self.isFinished else { return }
        if artwork != nil {
            self.winner = artwork
            self.complete()
        } else {
            self.pendingCount -= 1
            if self.pendingCount <= 0 {
                self.complete()
            }
        }
    }

    func value() async -> CanvasArtwork? {
        if self.isFinished {
            return self.winner
        }
        return await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    private func complete() {
        self.isFinished = true
        let result = self.winner
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }
}
