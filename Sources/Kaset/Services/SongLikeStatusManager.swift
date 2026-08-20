import Foundation

// MARK: - LikeStatusEvent

/// Represents a like status change event for reactive UI updates.
struct LikeStatusEvent: Equatable {
    let videoId: String
    let status: LikeStatus
    let song: Song?
    private let eventId = UUID()

    static func == (lhs: LikeStatusEvent, rhs: LikeStatusEvent) -> Bool {
        lhs.eventId == rhs.eventId
    }
}

// MARK: - SongLikeStatusManager

/// Manages like/dislike status for songs across the app.
/// This service caches like statuses locally and syncs with the YouTube Music API.
@MainActor
@Observable
final class SongLikeStatusManager {
    /// Shared singleton instance.
    static let shared = SongLikeStatusManager()

    private static let primaryAccountID = "primary"

    /// Cache of account ID to (video ID to like status).
    private var statusCacheByAccount: [String: [String: LikeStatus]] = [:]

    /// Currently active account scope for cache lookups.
    private(set) var activeAccountID = SongLikeStatusManager.primaryAccountID

    /// The most recent like status change event, for reactive observation by views.
    private(set) var lastLikeEvent: LikeStatusEvent?

    // MARK: - Coalescing / Retry Knobs

    /// How long to wait before sending a rating request so that rapid clicks collapse
    /// into a single network call. UI stays instant via the optimistic cache write.
    @ObservationIgnored
    var ratingDebounce: Duration = .milliseconds(150)

    /// Backoff delays between retry attempts (one entry per retry).
    /// Empty means no retries. Injectable for tests.
    @ObservationIgnored
    var ratingRetryDelays: [Duration] = [.milliseconds(500), .milliseconds(1500)]

    /// One coalesced rating "burst" for a single (account, video) pair.
    private struct RatingFlight {
        /// Sequence of the most recent intent in this burst.
        var latestSequence: Int
        /// Desired status of the most recent intent in this burst.
        var latestStatus: LikeStatus
        /// Cache status captured before the burst began; the rollback target on final failure.
        let baseline: LikeStatus?
        /// Handle to the current network request so a newer intent can cancel it.
        var requestTask: Task<Void, Never>?
    }

    /// Key identifying the rating scope for one song.
    private struct RatingKey: Hashable {
        let accountID: String
        let videoId: String
    }

    /// In-flight/coalesced rating bursts, keyed by (account, video).
    @ObservationIgnored
    private var ratingFlights: [RatingKey: RatingFlight] = [:]

    /// Reference to the YTMusic client for API calls.
    private var client: (any YTMusicClientProtocol)?

    private init() {}

    // MARK: - Configuration

    /// Sets the client to use for API calls.
    /// - Parameter client: The YTMusic client, or `nil` to clear the override.
    func setClient(_ client: (any YTMusicClientProtocol)?) {
        self.client = client
    }

    /// The currently configured client override.
    var currentClient: (any YTMusicClientProtocol)? {
        self.client
    }

    /// Updates the active account scope used for cache lookups and writes.
    /// - Parameter accountID: The active account identifier, or `nil` for the primary account.
    func setActiveAccountID(_ accountID: String?) {
        let resolvedAccountID = Self.resolvedAccountID(accountID)
        guard self.activeAccountID != resolvedAccountID else { return }

        self.activeAccountID = resolvedAccountID
        DiagnosticsLogger.api.debug("SongLikeStatusManager: Switched cache scope to account \(resolvedAccountID)")
    }

    // MARK: - Status Queries

    /// Gets the cached like status for a song.
    /// - Parameter videoId: The video ID of the song.
    /// - Returns: The cached status, or nil if not cached.
    func status(for videoId: String) -> LikeStatus? {
        self.status(for: videoId, accountID: self.activeAccountID)
    }

    /// Gets the like status for a song, using the song's own status as fallback.
    /// - Parameter song: The song to check.
    /// - Returns: The status from cache, song property, or nil.
    func status(for song: Song) -> LikeStatus? {
        self.status(for: song.videoId) ?? song.likeStatus
    }

    /// Checks if a song is liked.
    /// - Parameter song: The song to check.
    /// - Returns: True if the song is liked.
    func isLiked(_ song: Song) -> Bool {
        self.status(for: song) == .like
    }

    /// Checks if a song is disliked.
    /// - Parameter song: The song to check.
    /// - Returns: True if the song is disliked.
    func isDisliked(_ song: Song) -> Bool {
        self.status(for: song) == .dislike
    }

    // MARK: - Rating Actions

    /// Likes a song.
    /// - Parameters:
    ///   - song: The song to like.
    ///   - accountID: Optional account scope override.
    ///   - client: Optional client override.
    ///   - debounce: Debounce before sending, overriding the instance default. Lets
    ///     callers decide the coalescing window at click time.
    /// - Returns: The final status after the request settles.
    @discardableResult
    func like(
        _ song: Song,
        accountID: String? = nil,
        client: (any YTMusicClientProtocol)? = nil,
        debounce: Duration? = nil
    ) async -> LikeStatus {
        await self.rate(song, status: .like, accountID: accountID, client: client, debounce: debounce)
    }

    /// Unlikes a song (removes rating).
    /// - Parameters:
    ///   - song: The song to unlike.
    ///   - accountID: Optional account scope override.
    ///   - client: Optional client override.
    ///   - debounce: Debounce before sending, overriding the instance default.
    /// - Returns: The final status after the request settles.
    @discardableResult
    func unlike(
        _ song: Song,
        accountID: String? = nil,
        client: (any YTMusicClientProtocol)? = nil,
        debounce: Duration? = nil
    ) async -> LikeStatus {
        await self.rate(song, status: .indifferent, accountID: accountID, client: client, debounce: debounce)
    }

    /// Dislikes a song.
    /// - Parameters:
    ///   - song: The song to dislike.
    ///   - accountID: Optional account scope override.
    ///   - client: Optional client override.
    ///   - debounce: Debounce before sending, overriding the instance default.
    /// - Returns: The final status after the request settles.
    @discardableResult
    func dislike(
        _ song: Song,
        accountID: String? = nil,
        client: (any YTMusicClientProtocol)? = nil,
        debounce: Duration? = nil
    ) async -> LikeStatus {
        await self.rate(song, status: .dislike, accountID: accountID, client: client, debounce: debounce)
    }

    /// Undislikes a song (removes rating).
    /// - Parameters:
    ///   - song: The song to undislike.
    ///   - accountID: Optional account scope override.
    ///   - client: Optional client override.
    ///   - debounce: Debounce before sending, overriding the instance default.
    /// - Returns: The final status after the request settles.
    @discardableResult
    func undislike(
        _ song: Song,
        accountID: String? = nil,
        client: (any YTMusicClientProtocol)? = nil,
        debounce: Duration? = nil
    ) async -> LikeStatus {
        await self.rate(song, status: .indifferent, accountID: accountID, client: client, debounce: debounce)
    }

    /// Rates a song with the given status.
    ///
    /// Rapid successive calls for the same (account, video) are **coalesced**: each new
    /// intent supersedes the previous one (cancelling its in-flight request) and only the
    /// latest intent may settle state. A short debounce collapses rapid toggles into a
    /// single network request, and transient failures are retried with backoff.
    ///
    /// - Parameters:
    ///   - song: The song to rate.
    ///   - status: The rating to apply.
    ///   - accountID: Optional account scope override.
    ///   - client: Optional client override.
    /// - Returns: The cache-current status when the caller's intent settles. For intents
    ///   that were superseded, this is the newer intent's status, which makes the value
    ///   safe to write back by any observer.
    private func rate(
        _ song: Song,
        status: LikeStatus,
        accountID: String?,
        client overrideClient: (any YTMusicClientProtocol)?,
        debounce: Duration?
    ) async -> LikeStatus {
        let resolvedAccountID = accountID.map(Self.resolvedAccountID) ?? self.activeAccountID
        let key = RatingKey(accountID: resolvedAccountID, videoId: song.videoId)

        guard let client = overrideClient ?? self.client else {
            DiagnosticsLogger.api.warning("SongLikeStatusManager: No client set, cannot rate song")
            return self.status(for: song.videoId, accountID: resolvedAccountID) ?? song.likeStatus ?? .indifferent
        }

        // Coalesce: fold this intent into an existing burst (superseding and cancelling the
        // previous request), or start a new burst whose rollback baseline is the current
        // cache value.
        let sequence: Int
        if var flight = self.ratingFlights[key] {
            flight.requestTask?.cancel()
            sequence = flight.latestSequence + 1
            flight.latestSequence = sequence
            flight.latestStatus = status
            self.ratingFlights[key] = flight
        } else {
            sequence = 1
            self.ratingFlights[key] = RatingFlight(
                latestSequence: sequence,
                latestStatus: status,
                baseline: self.status(for: song.videoId, accountID: resolvedAccountID)
            )
        }

        // Optimistically update cache and notify observers
        self.setStatus(status, for: song.videoId, accountID: resolvedAccountID)
        self.publishEvent(
            LikeStatusEvent(videoId: song.videoId, status: status, song: song),
            for: resolvedAccountID
        )

        // Short debounce so rapid toggles collapse into a single network request.
        // The value is fixed at call time so a burst uses a consistent window.
        let effectiveDebounce = debounce ?? self.ratingDebounce
        try? await Task.sleep(for: effectiveDebounce)

        // If the caller's task was cancelled before anything was sent, undo the optimistic
        // write and drop the burst (matches the project's rollback-on-cancel rule).
        if Task.isCancelled {
            if self.ratingFlights[key]?.latestSequence == sequence {
                let baseline = self.ratingFlights[key]?.baseline
                self.restoreStatus(baseline, for: song.videoId, accountID: resolvedAccountID)
                self.publishEvent(
                    LikeStatusEvent(videoId: song.videoId, status: baseline ?? .indifferent, song: song),
                    for: resolvedAccountID
                )
                self.ratingFlights.removeValue(forKey: key)
            }
            return self.status(for: song.videoId, accountID: resolvedAccountID) ?? song.likeStatus ?? .indifferent
        }

        // If a newer intent superseded this one during the debounce, do nothing — the
        // newer intent owns the state and will send its own request.
        guard self.ratingFlights[key]?.latestSequence == sequence else {
            return self.status(for: song.videoId, accountID: resolvedAccountID) ?? song.likeStatus ?? .indifferent
        }

        let requestTask = Task { [weak self] in
            guard let self else { return }
            await self.executeRatingRequest(
                client: client,
                videoId: song.videoId,
                status: status,
                sequence: sequence,
                key: key,
                song: song
            )
        }
        self.ratingFlights[key]?.requestTask = requestTask
        await requestTask.value

        // Return the cache-current status so superseded/settled callers report the latest state.
        return self.status(for: song.videoId, accountID: resolvedAccountID) ?? song.likeStatus ?? .indifferent
    }

    /// Sends the rating request for one intent, with bounded retries.
    ///
    /// Only the latest intent for a key may settle state: if this intent was superseded
    /// (cancelled) it returns without touching the cache, and the final-failure rollback
    /// is guarded by a sequence check so an older request can never clobber a newer one.
    private func executeRatingRequest(
        client: any YTMusicClientProtocol,
        videoId: String,
        status: LikeStatus,
        sequence: Int,
        key: RatingKey,
        song: Song
    ) async {
        let retryDelays = self.ratingRetryDelays
        var lastError: (any Error)?

        for attempt in 0...retryDelays.count {
            if Task.isCancelled {
                // Superseded by a newer intent (or externally cancelled): the newer
                // intent owns the state, so do not settle anything.
                return
            }

            do {
                try await client.rateSong(videoId: videoId, rating: status)
                guard !Task.isCancelled else { return }
                DiagnosticsLogger.api.info("Rated song \(videoId) as \(status.rawValue)")
                // Burst settled successfully: re-assert the cache so a concurrent cache
                // clear (e.g. account switch) cannot leave a stale empty entry.
                self.setStatus(status, for: videoId, accountID: key.accountID)
                self.ratingFlights.removeValue(forKey: key)
                return
            } catch is CancellationError {
                return
            } catch {
                lastError = error
                if let ytError = error as? YTMusicError, !ytError.isRetryable {
                    break
                }
            }

            guard attempt < retryDelays.count else { break }
            do {
                try await Task.sleep(for: retryDelays[attempt])
            } catch {
                return  // Cancelled during backoff
            }
        }

        // Final failure: roll back to the pre-burst baseline, but only if this intent is
        // still the latest (a newer intent owns the state otherwise).
        guard self.ratingFlights[key]?.latestSequence == sequence else { return }
        let baseline = self.ratingFlights[key]?.baseline
        self.restoreStatus(baseline, for: videoId, accountID: key.accountID)
        self.publishEvent(
            LikeStatusEvent(videoId: videoId, status: baseline ?? .indifferent, song: song),
            for: key.accountID
        )
        self.ratingFlights.removeValue(forKey: key)
        DiagnosticsLogger.api.error(
            "Failed to rate song \(videoId) as \(status.rawValue): \(lastError?.localizedDescription ?? "unknown error")"
        )
    }

    // MARK: - Cache Management

    /// Updates the cache with a known status (e.g., from API response).
    /// - Parameters:
    ///   - videoId: The video ID.
    ///   - status: The like status.
    func setStatus(_ status: LikeStatus, for videoId: String) {
        self.setStatus(status, for: videoId, accountID: self.activeAccountID)
    }

    /// Clears all cached statuses.
    func clearCache() {
        self.statusCacheByAccount.removeAll()
        self.lastLikeEvent = nil
    }

    private static func resolvedAccountID(_ accountID: String?) -> String {
        accountID ?? self.primaryAccountID
    }

    func status(for videoId: String, accountID: String?) -> LikeStatus? {
        self.statusCacheByAccount[Self.resolvedAccountID(accountID)]?[videoId]
    }

    private func setStatus(_ status: LikeStatus, for videoId: String, accountID: String) {
        var cache = self.statusCacheByAccount[accountID] ?? [:]
        cache[videoId] = status
        self.statusCacheByAccount[accountID] = cache
    }

    private func restoreStatus(_ status: LikeStatus?, for videoId: String, accountID: String) {
        if let status {
            self.setStatus(status, for: videoId, accountID: accountID)
        } else {
            self.removeStatus(for: videoId, accountID: accountID)
        }
    }

    private func removeStatus(for videoId: String, accountID: String) {
        guard var cache = self.statusCacheByAccount[accountID] else { return }

        cache.removeValue(forKey: videoId)
        if cache.isEmpty {
            self.statusCacheByAccount.removeValue(forKey: accountID)
        } else {
            self.statusCacheByAccount[accountID] = cache
        }
    }

    private func publishEvent(_ event: LikeStatusEvent, for accountID: String) {
        guard accountID == self.activeAccountID else { return }
        self.lastLikeEvent = event
    }
}
