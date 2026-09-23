import Foundation
import Observation
import os

/// View model for the PlaylistDetailView.
@MainActor
@Observable
final class PlaylistDetailViewModel {
    /// Current loading state.
    private(set) var loadingState: LoadingState = .idle

    /// The loaded playlist detail.
    private(set) var playlistDetail: PlaylistDetail?

    /// Whether more tracks are available to load.
    private(set) var hasMore: Bool = false

    private let playlist: Playlist
    /// The API client (exposed for add to library action).
    let client: any YTMusicClientProtocol
    private let logger = DiagnosticsLogger.api

    /// Video IDs already loaded. Maintained incrementally so appending a page doesn't rebuild a
    /// set over every loaded track.
    private var loadedVideoIds: Set<String> = []

    /// In-flight page load, shared so a scroll-triggered page and a background prefill never
    /// issue two continuation requests against the same token.
    private var inFlightPageLoad: Task<Bool, Never>?

    /// Background task that keeps a page of headroom below the loaded tracks.
    // swiftformat:disable modifierOrder
    /// nonisolated(unsafe) required for deinit access; Swift 6.2 warning is expected.
    nonisolated(unsafe) private var prefillTask: Task<Void, Never>?
    // swiftformat:enable modifierOrder

    /// Generation counter so a cancelled prefill can't clear the handle of a newer one.
    private var prefillGeneration = 0

    /// Whether loading a playlist prefetches the following page in the background. Tests turn
    /// this off to keep page accounting deterministic.
    var prefetchesFollowingPage = true

    init(playlist: Playlist, client: any YTMusicClientProtocol) {
        self.playlist = playlist
        self.client = client
    }

    deinit {
        self.prefillTask?.cancel()
    }

    /// Strips song count patterns from author text (e.g., " • 145 songs" or " • 2,429 tracks").
    /// Used to clean fallback author values that may contain redundant song counts.
    private func stripSongCount(from text: String?) -> String? {
        guard var result = text else { return nil }
        result = result.replacingOccurrences(
            of: #" • [\d,]+ (?:songs?|tracks?)"#,
            with: "",
            options: .regularExpression
        )
        if result.hasPrefix(" • ") {
            result = String(result.dropFirst(3))
        }
        result = result.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }

    /// Loads the playlist details including tracks.
    func load() async {
        guard self.loadingState != .loading else { return }

        self.loadingState = .loading
        let playlistTitle = self.playlist.title
        let playlistId = self.playlist.id
        self.logger.info("Loading playlist: \(playlistTitle), ID: \(playlistId)")

        do {
            let result = try await self.fetchPlaylistDetail()
            self.playlistDetail = result.detail
            self.loadedVideoIds = Set(result.detail.tracks.map(\.videoId))
            self.hasMore = result.hasMore
            self.loadingState = .loaded
            let loadedTrackCount = result.detail.tracks.count
            let totalTrackCount = result.detail.trackCount ?? loadedTrackCount
            self.logger.info("Playlist loaded: \(loadedTrackCount) loaded tracks, total: \(totalTrackCount), hasMore: \(self.hasMore)")

            // Keep a page of headroom below the loaded tracks so a fast scroll never waits on the network.
            self.prefillNextPage()
        } catch is CancellationError {
            // Task was cancelled (e.g., user navigated away) — reset to idle so it can retry
            self.logger.debug("Playlist detail load cancelled")
            self.loadingState = .idle
        } catch {
            self.logger.error("Failed to load playlist: \(error.localizedDescription)")
            self.loadingState = .error(LoadingError(from: error))
        }
    }

    private func fetchPlaylistDetail() async throws -> (detail: PlaylistDetail, hasMore: Bool) {
        // For radio playlists (RDCLAK prefix), use the queue API to get all tracks at once
        // This bypasses the broken continuation pagination for these playlists
        // Check for both VL-prefixed and raw RDCLAK IDs
        let playlistId = self.playlist.id
        let isRadioPlaylist = playlistId.contains("RDCLAK") || playlistId.hasPrefix("RD")
        self.logger.debug("Playlist ID: \(playlistId), isRadioPlaylist: \(isRadioPlaylist)")

        let response = try await client.getPlaylist(id: playlistId)
        var detail = response.detail
        var hasMore = response.hasMore

        // If it's a radio playlist, always fetch all tracks via queue API
        // The browse API often returns hasMore=false even when there are more tracks
        if isRadioPlaylist {
            self.logger.info("Radio playlist detected, fetching all tracks via queue API")
            do {
                let allTracks = try await client.getPlaylistAllTracks(playlistId: playlistId)
                if allTracks.count > detail.tracks.count {
                    self.logger.info("Queue API returned \(allTracks.count) tracks (vs \(detail.tracks.count) from browse)")
                    // Update the detail with all tracks from queue API
                    let updatedPlaylist = Playlist(
                        id: detail.id,
                        title: detail.title,
                        description: detail.description,
                        thumbnailURL: detail.thumbnailURL,
                        trackCount: allTracks.count,
                        author: detail.author
                    )
                    detail = PlaylistDetail(
                        playlist: updatedPlaylist,
                        tracks: allTracks,
                        duration: detail.duration
                    )
                    hasMore = false
                }
            } catch {
                // If queue API fails, fall back to browse results
                self.logger.warning("Queue API failed, using browse results: \(error.localizedDescription)")
            }
        }

        // Determine the best thumbnail to use:
        // 1. API response header thumbnail
        // 2. Original playlist thumbnail (from navigation)
        // 3. First track's thumbnail as fallback
        let resolvedThumbnailURL = detail.thumbnailURL
            ?? self.playlist.thumbnailURL
            ?? detail.tracks.first?.thumbnailURL

        // Check if we need to merge with original playlist info
        let needsMerge = detail.title == "Unknown Playlist" && self.playlist.title != "Unknown Playlist"
        let thumbnailMissing = detail.thumbnailURL == nil && resolvedThumbnailURL != nil

        if needsMerge || thumbnailMissing {
            let mergedTrackCount = max(
                detail.tracks.count,
                max(detail.trackCount ?? 0, self.playlist.trackCount ?? 0)
            )

            // Merge with original playlist info or add fallback thumbnail
            // Strip song counts from fallback author since we display the count separately
            let mergedPlaylist = Playlist(
                id: playlistId,
                title: needsMerge ? self.playlist.title : detail.title,
                description: detail.description ?? self.playlist.description,
                thumbnailURL: resolvedThumbnailURL,
                trackCount: mergedTrackCount,
                author: detail.author ?? self.stripSongCount(from: self.playlist.author)
            )
            detail = PlaylistDetail(
                playlist: mergedPlaylist,
                tracks: detail.tracks,
                duration: detail.duration,
                artists: detail.artists
            )
        }

        return (detail: self.fillingArtistsFromAlbum(detail), hasMore: hasMore)
    }

    /// Album pages list their tracks without bylines, so a row would show no artist even though the
    /// album header credits them. Filling those rows keeps the artist visible in the list and gives
    /// playback and the row menu (Go to Artist) the album's artists.
    private func fillingArtistsFromAlbum(_ detail: PlaylistDetail) -> PlaylistDetail {
        guard detail.isAlbum,
              !detail.artists.isEmpty,
              detail.tracks.contains(where: { $0.artists.isEmpty })
        else {
            return detail
        }

        let album = Album(
            id: detail.id,
            title: detail.title,
            artists: detail.artists,
            thumbnailURL: detail.thumbnailURL,
            year: nil,
            trackCount: detail.trackCount
        )

        let tracks = detail.tracks.map { song -> Song in
            guard song.artists.isEmpty else { return song }

            return Song(
                id: song.id,
                title: song.title,
                artists: detail.artists,
                album: song.album ?? album,
                duration: song.duration,
                thumbnailURL: song.thumbnailURL,
                videoId: song.videoId,
                hasVideo: song.hasVideo,
                musicVideoType: song.musicVideoType,
                likeStatus: song.likeStatus,
                isInLibrary: song.isInLibrary,
                feedbackTokens: song.feedbackTokens
            )
        }

        let playlist = Playlist(
            id: detail.id,
            title: detail.title,
            description: detail.description,
            thumbnailURL: detail.thumbnailURL,
            trackCount: detail.trackCount,
            author: detail.author
        )

        return PlaylistDetail(
            playlist: playlist,
            tracks: tracks,
            duration: detail.duration,
            artists: detail.artists
        )
    }

    /// Loads more tracks via continuation.
    ///
    /// Driven by scroll proximity rather than a row callback, so the request starts while there
    /// is still content below the visible window and the spinner stays off-screen.
    func loadMore() async {
        _ = await self.loadNextPage(showIndicator: true)
    }

    /// Keeps one continuation page of headroom below the loaded tracks so a fast scroll never
    /// has to wait on the network. Fire-and-forget by design: the loaded tracks already fill the
    /// window, so there is nothing to await.
    private func prefillNextPage() {
        guard self.prefetchesFollowingPage, self.prefillTask == nil, self.hasMore else { return }

        self.prefillGeneration += 1
        let generation = self.prefillGeneration
        self.prefillTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.loadNextPage(showIndicator: false)
            if self.prefillGeneration == generation {
                self.prefillTask = nil
            }
        }
    }

    /// Loads the next page, coalescing concurrent requests into one continuation call.
    /// - Parameter showIndicator: Whether to surface the loading indicator for this page.
    /// - Returns: Whether a page was appended.
    private func loadNextPage(showIndicator: Bool) async -> Bool {
        // A page is already on the way — wait for it instead of issuing a second request.
        if let inFlightPageLoad {
            return await inFlightPageLoad.value
        }

        guard self.hasMore, self.playlistDetail != nil else { return false }

        if showIndicator {
            self.loadingState = .loadingMore
        }
        self.logger.info("Loading more playlist tracks")

        let page = Task { await self.appendNextPage() }
        self.inFlightPageLoad = page
        let didAppend = await page.value
        self.inFlightPageLoad = nil

        if showIndicator {
            // Keep loaded state so the user can retry a failed page.
            self.loadingState = .loaded
        }

        return didAppend
    }

    /// Fetches one continuation page and appends its unique tracks.
    private func appendNextPage() async -> Bool {
        do {
            guard let response = try await client.getPlaylistContinuation() else {
                self.hasMore = false
                self.logger.info("No playlist continuation available, stopping pagination")
                return false
            }

            // A cancelled page (refresh or navigation) must not mutate the list.
            guard !Task.isCancelled else {
                self.logger.debug("Playlist continuation cancelled")
                return false
            }

            // Dedupe against the incrementally maintained set, which also records the new IDs.
            // This handles radio playlists that return overlapping data.
            let newTracks = response.tracks.filter { self.loadedVideoIds.insert($0.videoId).inserted }

            // If no new unique tracks were added, stop pagination.
            guard !newTracks.isEmpty, let currentDetail = self.playlistDetail else {
                self.hasMore = false
                self.logger.info("No new unique tracks in continuation, stopping pagination")
                return false
            }

            // Append only new tracks to existing playlist
            let allTracks = currentDetail.tracks + newTracks
            let preservedTrackCount = max(allTracks.count, currentDetail.trackCount ?? 0)
            let updatedPlaylist = Playlist(
                id: currentDetail.id,
                title: currentDetail.title,
                description: currentDetail.description,
                thumbnailURL: currentDetail.thumbnailURL,
                trackCount: preservedTrackCount,
                author: currentDetail.author
            )
            self.playlistDetail = self.fillingArtistsFromAlbum(PlaylistDetail(
                playlist: updatedPlaylist,
                tracks: allTracks,
                duration: currentDetail.duration,
                artists: currentDetail.artists
            ))
            self.hasMore = response.hasMore

            let loadedTrackCount = allTracks.count
            self.logger.info("Loaded \(newTracks.count) new tracks (from \(response.tracks.count)), loaded total: \(loadedTrackCount), reported total: \(preservedTrackCount), hasMore: \(self.hasMore)")
            return true
        } catch is CancellationError {
            self.logger.debug("Playlist continuation cancelled")
            return false
        } catch {
            self.logger.error("Failed to load more playlist tracks: \(error.localizedDescription)")
            return false
        }
    }

    /// Refreshes the playlist.
    func refresh() async {
        // A refresh replaces the track list, so any in-flight prefill or page fetch is stale.
        self.prefillGeneration += 1
        self.prefillTask?.cancel()
        self.prefillTask = nil
        self.inFlightPageLoad?.cancel()
        self.inFlightPageLoad = nil

        // Manual refresh should fetch fresh data instead of reusing browse cache.
        APICache.shared.invalidate(matching: "browse:")
        guard self.loadingState != .loading, self.loadingState != .loadingMore else { return }

        guard self.playlistDetail != nil, self.loadingState == .loaded else {
            self.playlistDetail = nil
            self.hasMore = false
            await self.load()
            return
        }

        let playlistTitle = self.playlist.title
        let playlistId = self.playlist.id
        self.logger.info("Refreshing playlist in background: \(playlistTitle), ID: \(playlistId)")

        do {
            let result = try await self.fetchPlaylistDetail()
            self.playlistDetail = result.detail
            self.loadedVideoIds = Set(result.detail.tracks.map(\.videoId))
            self.hasMore = result.hasMore
            let loadedTrackCount = result.detail.tracks.count
            let totalTrackCount = result.detail.trackCount ?? loadedTrackCount
            self.logger.info("Playlist refreshed: \(loadedTrackCount) loaded tracks, total: \(totalTrackCount), hasMore: \(self.hasMore)")
            self.prefillNextPage()
        } catch is CancellationError {
            self.logger.debug("Playlist refresh cancelled")
        } catch {
            // Keep showing the existing detail while refresh fails.
            self.logger.warning("Playlist refresh failed, keeping existing detail: \(error.localizedDescription)")
        }
    }
}
