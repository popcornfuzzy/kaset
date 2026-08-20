import Foundation
import Testing
@testable import Kaset

/// Tests for SongLikeStatusManager.
@Suite(.serialized, .tags(.service))
@MainActor
struct SongLikeStatusManagerTests {
    var manager: SongLikeStatusManager
    var mockClient: MockYTMusicClient

    init() {
        // Use the shared singleton (init is private)
        self.manager = SongLikeStatusManager.shared
        self.mockClient = MockYTMusicClient()
        self.manager.clearCache()
        self.manager.setActiveAccountID(nil)
        // Keep the suite deterministic: no debounce or retries unless a test opts in.
        self.manager.ratingDebounce = .zero
        self.manager.ratingRetryDelays = []
    }

    /// Resets shared state so each test is deterministic regardless of suite execution
    /// order (tests within a suite run serially but in arbitrary order) and concurrent
    /// suites that share the singleton (e.g. AccountServiceTests switches accounts).
    /// Returns the pinned account ID to pass explicitly to rating calls.
    private func prepareTest() -> String {
        self.manager.clearCache()
        self.manager.setActiveAccountID(nil)
        self.mockClient.reset()
        self.mockClient.shouldThrowError = nil
        self.mockClient.rateSongDelay = nil
        self.mockClient.rateSongFailuresBeforeSuccess = 0
        return "primary"
    }

    /// Reads the like status scoped to the primary account, immune to concurrent
    /// account switches from other suites sharing the singleton.
    private func primaryStatus(for videoId: String) -> LikeStatus? {
        self.manager.status(for: videoId, accountID: nil)
    }

    // MARK: - Status Query Tests

    @Test("status for videoId returns nil when not cached")
    func statusForVideoIdReturnsNilWhenNotCached() {
        let status = self.manager.status(for: "unknown-video")
        #expect(status == nil)
    }

    @Test("status for videoId returns cached value")
    func statusForVideoIdReturnsCached() {
        self.manager.setStatus(.like, for: "manager-rating-video")

        let status = self.manager.status(for: "manager-rating-video")

        #expect(status == .like)
    }

    @Test("status for song uses cache over song property")
    func statusForSongUsesCacheOverProperty() {
        let song = Song(
            id: "manager-rating-video",
            title: "Test",
            artists: [],
            videoId: "manager-rating-video",
            likeStatus: .dislike
        )
        self.manager.setStatus(.like, for: "manager-rating-video")

        let status = self.manager.status(for: song)

        #expect(status == .like) // Cache takes precedence
    }

    @Test("status for song falls back to song property")
    func statusForSongFallsBackToProperty() {
        let song = Song(
            id: "manager-rating-video",
            title: "Test",
            artists: [],
            videoId: "manager-rating-video",
            likeStatus: .dislike
        )
        // No cache set

        let status = self.manager.status(for: song)

        #expect(status == .dislike)
    }

    @Test("isLiked returns true when liked")
    func isLikedReturnsTrue() {
        let song = TestFixtures.makeSong(id: "manager-rating-video")
        self.manager.setStatus(.like, for: "manager-rating-video")

        #expect(self.manager.isLiked(song) == true)
        #expect(self.manager.isDisliked(song) == false)
    }

    @Test("isDisliked returns true when disliked")
    func isDislikedReturnsTrue() {
        let song = TestFixtures.makeSong(id: "manager-rating-video")
        self.manager.setStatus(.dislike, for: "manager-rating-video")

        #expect(self.manager.isDisliked(song) == true)
        #expect(self.manager.isLiked(song) == false)
    }

    // MARK: - Rating Action Tests

    @Test("like updates cache and calls API")
    func likeUpdatesCacheAndCallsAPI() async {
        let accountID = self.prepareTest()
        let song = TestFixtures.makeSong(id: "manager-rating-video")

        await self.manager.like(song, accountID: accountID, client: self.mockClient)

        #expect(self.primaryStatus(for: "manager-rating-video") == .like)
        #expect(self.mockClient.rateSongCalled == true)
        #expect(self.mockClient.rateSongVideoIds.first == "manager-rating-video")
        #expect(self.mockClient.rateSongRatings.first == .like)
    }

    @Test("unlike updates cache to indifferent")
    func unlikeUpdatesCacheToIndifferent() async {
        let accountID = self.prepareTest()
        let song = TestFixtures.makeSong(id: "manager-rating-video")
        self.manager.setStatus(.like, for: "manager-rating-video")

        await self.manager.unlike(song, accountID: accountID, client: self.mockClient)

        #expect(self.primaryStatus(for: "manager-rating-video") == .indifferent)
        #expect(self.mockClient.rateSongRatings.first == .indifferent)
    }

    @Test("dislike updates cache and calls API")
    func dislikeUpdatesCacheAndCallsAPI() async {
        let accountID = self.prepareTest()
        let song = TestFixtures.makeSong(id: "manager-rating-video")

        await self.manager.dislike(song, accountID: accountID, client: self.mockClient)

        #expect(self.primaryStatus(for: "manager-rating-video") == .dislike)
        #expect(self.mockClient.rateSongRatings.first == .dislike)
    }

    @Test("undislike updates cache to indifferent")
    func undislikeUpdatesCacheToIndifferent() async {
        let accountID = self.prepareTest()
        let song = TestFixtures.makeSong(id: "manager-rating-video")
        self.manager.setStatus(.dislike, for: "manager-rating-video")

        await self.manager.undislike(song, accountID: accountID, client: self.mockClient)

        #expect(self.primaryStatus(for: "manager-rating-video") == .indifferent)
    }

    // MARK: - Coalescing Tests

    @Test("rapid like then unlike coalesces to a single request with the final intent")
    func rapidLikeThenUnlikeCoalesces() async {
        let accountID = self.prepareTest()
        let song = TestFixtures.makeSong(id: "manager-rating-video")
        let debounce: Duration = .milliseconds(80)

        let first = Task { await self.manager.like(song, accountID: accountID, client: self.mockClient, debounce: debounce) }
        try? await Task.sleep(for: .milliseconds(10))
        let second = Task { await self.manager.unlike(song, accountID: accountID, client: self.mockClient, debounce: debounce) }

        _ = await first.value
        _ = await second.value

        #expect(self.mockClient.rateSongCalled == true)
        #expect(self.mockClient.rateSongVideoIds.count == 1)
        #expect(self.mockClient.rateSongRatings == [.indifferent])
        #expect(self.primaryStatus(for: "manager-rating-video") == .indifferent)
    }

    @Test("rapid like-unlike-like coalesces to a single request with the last intent")
    func rapidTripleToggleCoalesces() async {
        let accountID = self.prepareTest()
        let song = TestFixtures.makeSong(id: "manager-rating-video")
        let debounce: Duration = .milliseconds(100)

        let first = Task { await self.manager.like(song, accountID: accountID, client: self.mockClient, debounce: debounce) }
        try? await Task.sleep(for: .milliseconds(10))
        let second = Task { await self.manager.unlike(song, accountID: accountID, client: self.mockClient, debounce: debounce) }
        try? await Task.sleep(for: .milliseconds(10))
        let third = Task { await self.manager.like(song, accountID: accountID, client: self.mockClient, debounce: debounce) }

        _ = await first.value
        _ = await second.value
        _ = await third.value

        #expect(self.mockClient.rateSongVideoIds.count == 1)
        #expect(self.mockClient.rateSongRatings == [.like])
        #expect(self.primaryStatus(for: "manager-rating-video") == .like)
    }

    @Test("new intent cancels an in-flight request without rolling back the newer intent")
    func newIntentCancelsInflightRequest() async {
        let accountID = self.prepareTest()
        let song = TestFixtures.makeSong(id: "manager-rating-video")
        self.manager.ratingDebounce = .zero
        self.mockClient.rateSongDelay = .milliseconds(150)

        let first = Task { await self.manager.like(song, accountID: accountID, client: self.mockClient) }
        try? await Task.sleep(for: .milliseconds(10))
        let second = Task { await self.manager.unlike(song, accountID: accountID, client: self.mockClient) }

        let firstResult = await first.value
        let secondResult = await second.value

        // Both requests were recorded, but the first was cancelled before settling and
        // must not roll back over the newer (successful) intent.
        #expect(self.primaryStatus(for: "manager-rating-video") == .indifferent)
        #expect(firstResult == .indifferent)
        #expect(secondResult == .indifferent)
        #expect(self.mockClient.rateSongVideoIds.count == 2)
        #expect(self.mockClient.rateSongRatings == [.like, .indifferent])
    }

    @Test("failed intent in a burst rolls back to the pre-burst baseline")
    func failedBurstIntentRollsBackToBaseline() async {
        let accountID = self.prepareTest()
        let song = TestFixtures.makeSong(id: "manager-rating-video")
        let debounce: Duration = .milliseconds(80)
        self.manager.ratingRetryDelays = []
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        let first = Task { await self.manager.like(song, accountID: accountID, client: self.mockClient, debounce: debounce) }
        try? await Task.sleep(for: .milliseconds(10))
        let second = Task { await self.manager.unlike(song, accountID: accountID, client: self.mockClient, debounce: debounce) }

        _ = await first.value
        _ = await second.value

        // The like was superseded before it was sent (only the unlike hit the network);
        // the unlike failed, so we roll back to the pre-burst baseline (no cached status).
        #expect(self.mockClient.rateSongVideoIds.count == 1)
        #expect(self.mockClient.rateSongRatings == [.indifferent])
        #expect(self.primaryStatus(for: "manager-rating-video") == nil)
    }

    @Test("failed older request does not clobber a newer intent")
    func failedOlderRequestDoesNotClobberNewer() async {
        let accountID = self.prepareTest()
        let song = TestFixtures.makeSong(id: "manager-rating-video")
        self.manager.ratingDebounce = .zero
        self.manager.ratingRetryDelays = []
        self.mockClient.rateSongDelay = .milliseconds(100)
        self.mockClient.rateSongFailuresBeforeSuccess = 1  // first call fails, second succeeds

        let first = Task { await self.manager.like(song, accountID: accountID, client: self.mockClient) }
        try? await Task.sleep(for: .milliseconds(10))
        let second = Task { await self.manager.unlike(song, accountID: accountID, client: self.mockClient) }

        let firstResult = await first.value
        let secondResult = await second.value

        #expect(self.primaryStatus(for: "manager-rating-video") == .indifferent)
        #expect(firstResult == .indifferent)
        #expect(secondResult == .indifferent)
        #expect(self.mockClient.rateSongVideoIds.count == 2)
    }

    // MARK: - Retry Tests

    @Test("transient rating failure is retried and keeps the liked status")
    func transientFailureIsRetried() async {
        let accountID = self.prepareTest()
        let song = TestFixtures.makeSong(id: "manager-rating-video")
        self.manager.ratingDebounce = .zero
        self.manager.ratingRetryDelays = [.milliseconds(10)]
        defer { self.manager.ratingRetryDelays = [] }
        self.mockClient.rateSongFailuresBeforeSuccess = 1

        let result = await self.manager.like(song, accountID: accountID, client: self.mockClient)

        #expect(result == .like)
        #expect(self.primaryStatus(for: "manager-rating-video") == .like)
        #expect(self.mockClient.rateSongVideoIds.count == 2)  // initial + 1 retry
        #expect(self.mockClient.rateSongRatings == [.like, .like])
    }

    @Test("rating rolls back to baseline when retries are exhausted")
    func rollsBackWhenRetriesExhausted() async {
        let accountID = self.prepareTest()
        let song = TestFixtures.makeSong(id: "manager-rating-video")
        self.manager.ratingDebounce = .zero
        self.manager.ratingRetryDelays = [.milliseconds(10)]
        defer { self.manager.ratingRetryDelays = [] }
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        let result = await self.manager.like(song, accountID: accountID, client: self.mockClient)

        #expect(result == .indifferent)
        #expect(self.primaryStatus(for: "manager-rating-video") == nil)  // baseline was nil
        #expect(self.mockClient.rateSongVideoIds.count == 2)  // initial + 1 retry
    }

    // MARK: - Error Handling Tests

    @Test("like reverts cache on API failure")
    func likeRevertsCacheOnFailure() async {
        let accountID = self.prepareTest()
        let song = TestFixtures.makeSong(id: "manager-rating-video")
        self.manager.setStatus(.indifferent, for: "manager-rating-video")
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.manager.like(song, accountID: accountID, client: self.mockClient)

        // Should revert to previous status
        #expect(self.primaryStatus(for: "manager-rating-video") == .indifferent)
    }

    @Test("like removes cache entry on failure when no previous")
    func likeRemovesCacheOnFailureWhenNoPrevious() async {
        let accountID = self.prepareTest()
        let song = TestFixtures.makeSong(id: "new-video")
        // No previous status set
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.manager.like(song, accountID: accountID, client: self.mockClient)

        // Should remove the entry entirely
        #expect(self.primaryStatus(for: "new-video") == nil)
    }

    @Test("dislike reverts cache on API failure")
    func dislikeRevertsCacheOnFailure() async {
        let accountID = self.prepareTest()
        let song = TestFixtures.makeSong(id: "manager-rating-video")
        self.manager.setStatus(.like, for: "manager-rating-video")
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))

        await self.manager.dislike(song, accountID: accountID, client: self.mockClient)

        // Should revert to previous status
        #expect(self.primaryStatus(for: "manager-rating-video") == .like)
    }

    // MARK: - Cache Management Tests

    @Test("setStatus updates cache")
    func setStatusUpdatesCache() {
        self.manager.setStatus(.like, for: "video-1")
        self.manager.setStatus(.dislike, for: "video-2")

        #expect(self.manager.status(for: "video-1") == .like)
        #expect(self.manager.status(for: "video-2") == .dislike)
    }

    @Test("cache is isolated by active account")
    func cacheIsIsolatedByActiveAccount() {
        self.manager.setActiveAccountID("primary")
        self.manager.setStatus(.like, for: "video-1")

        self.manager.setActiveAccountID("brand-account")
        #expect(self.manager.status(for: "video-1") == nil)

        self.manager.setStatus(.dislike, for: "video-1")
        #expect(self.manager.status(for: "video-1") == .dislike)

        self.manager.setActiveAccountID("primary")
        #expect(self.manager.status(for: "video-1") == .like)
    }

    @Test("clearCache removes all entries")
    func clearCacheRemovesAllEntries() {
        self.manager.setStatus(.like, for: "video-1")
        self.manager.setStatus(.dislike, for: "video-2")

        self.manager.clearCache()

        #expect(self.manager.status(for: "video-1") == nil)
        #expect(self.manager.status(for: "video-2") == nil)
    }
}
