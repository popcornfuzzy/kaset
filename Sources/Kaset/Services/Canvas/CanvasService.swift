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

    /// - Parameter providers: Preference-ordered; the first one to return a canvas
    ///   wins. Defaults to Tidal (primary) with Apple Music as the fallback.
    init(
        providers: [any CanvasProvider]? = nil,
        lookupCache: CanvasCache = .shared,
        videoFileCache: CanvasVideoFileCache = .shared
    ) {
        // Order is the preference order, so Tidal must stay first: it is the
        // album-level source and matches the fullscreen artwork far more often than
        // Apple Music's artist-level motion artwork.
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

    /// Consults providers in preference order and returns the first canvas found.
    ///
    /// Providers are tried one at a time rather than raced. Racing let whichever
    /// source returned first win, so "Tidal is primary" was not actually enforced —
    /// a slower but lower-priority provider could still decide the result for a
    /// track. It also ran Apple Music's web-player token scrape for every single
    /// lookup even though Tidal answers almost always, and the fallback is the only
    /// thing that benefits from starting early. Sequential lookup keeps the winner
    /// deterministic at the cost of adding the primary's runtime (well under a
    /// second when it hits) to a miss.
    @MainActor
    private static func searchProviders(
        providers: [any CanvasProvider],
        info: CanvasSearchInfo
    ) async -> CanvasCache.LookupResult {
        for provider in providers {
            if Task.isCancelled { return .notFound }
            if let artwork = await provider.fetchCanvas(for: info) {
                DiagnosticsLogger.ui.debug(
                    "Canvas provider \(provider.name, privacy: .public) FOUND a canvas for \(info.videoId, privacy: .public): \(artwork.videoURL.absoluteString, privacy: .public)"
                )
                return .found(artwork)
            }
            DiagnosticsLogger.ui.debug(
                "Canvas provider \(provider.name, privacy: .public) returned nothing for \(info.videoId, privacy: .public)"
            )
        }
        return .notFound
    }
}
