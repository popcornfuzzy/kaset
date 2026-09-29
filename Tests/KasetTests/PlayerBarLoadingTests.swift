import Foundation
import Testing
@testable import Kaset

/// The player bar's loading strip exists to make waits visible: the YouTube Music page that used to
/// be booted on the user's first press of play (now preloaded at launch) and the window between a
/// page being up and audio actually starting. These tests pin how those two turn into a drawing, the
/// quantization that keeps the WebView's per-frame progress from redrawing the bar, and the rules
/// that decide when the player layer is hosted and when the shell is loaded into it.
@Suite(.serialized, .tags(.service))
@MainActor
struct PlayerBarLoadingTests {
    private var playerService: PlayerService

    init() {
        self.playerService = PlayerService()
    }

    // MARK: - What the strip draws

    @Test("A page load has a fraction, so the strip fills from the left")
    func pageLoadFillsTheStrip() {
        let indicator = PlayerBarLoadingRule.indicator(pageLoadFraction: 0.4, isStartingPlayback: false)

        #expect(indicator == PlayerBarLoadingIndicator(style: .determinate, fraction: 0.4))
        #expect(indicator?.isIndeterminate == false)
    }

    @Test("A page load outranks the start-up wait, which has nothing to measure")
    func pageLoadOutranksStartup() {
        let indicator = PlayerBarLoadingRule.indicator(pageLoadFraction: 0.2, isStartingPlayback: true)

        #expect(indicator?.style == .determinate)
        #expect(indicator?.fraction == 0.2)
    }

    @Test("Waiting for audio to start breathes in place")
    func startingPlaybackBreathes() {
        let indicator = PlayerBarLoadingRule.indicator(pageLoadFraction: nil, isStartingPlayback: true)

        #expect(indicator?.style == .indeterminate)
        #expect(indicator?.isIndeterminate == true)
    }

    @Test("Nothing loading means no strip at all")
    func idleHasNoStrip() {
        #expect(PlayerBarLoadingRule.indicator(pageLoadFraction: nil, isStartingPlayback: false) == nil)
    }

    @Test("A fraction outside the bar is clamped to it")
    func fractionIsClamped() {
        #expect(PlayerBarLoadingIndicator(style: .determinate, fraction: 1.4).fraction == 1)
        #expect(PlayerBarLoadingIndicator(style: .determinate, fraction: -0.2).fraction == 0)
    }

    // MARK: - Following a page load through the service

    @Test("A page load fills the strip, then hands over to the start-up wait, then clears")
    func serviceFollowsAPageLoad() {
        self.playerService.state = .loading

        self.playerService.beginWebViewPageLoad()
        #expect(self.playerService.playerBarLoading == PlayerBarLoadingIndicator(style: .determinate, fraction: 0))

        self.playerService.updateWebViewPageLoadProgress(0.42)
        #expect(self.playerService.playerBarLoading?.fraction == 0.42)

        // The document is up but the song has not started: there is nothing left to measure.
        self.playerService.finishWebViewPageLoad()
        #expect(self.playerService.playerBarLoading?.style == .indeterminate)

        // Audio starts: the bar has nothing to wait for.
        self.playerService.state = .playing
        #expect(self.playerService.playerBarLoading == nil)
    }

    @Test("The launch preload fills the strip while the app is idle")
    func preloadFillsTheStripWhileIdle() {
        #expect(self.playerService.state == .idle)

        self.playerService.beginWebViewPageLoad()
        self.playerService.updateWebViewPageLoadProgress(0.7)

        #expect(self.playerService.playerBarLoading?.fraction == 0.7)

        // The page is up and nothing is playing. Without a tail configured the stripe ends with the
        // load, which is the case this test pins; with one, it keeps pulsing (see below).
        self.playerService.webViewLoadingLingerDuration = 0
        self.playerService.finishWebViewPageLoad()
        #expect(self.playerService.playerBarLoading == nil)
    }

    @Test("A paused player waits for nothing")
    func pausedPlayerShowsNoStrip() {
        self.playerService.state = .paused

        #expect(self.playerService.playerBarLoading == nil)
    }

    // MARK: - The tail that keeps the stripe up long enough to be seen

    @Test("A load that ended keeps the stripe pulsing for a tail")
    func finishedLoadKeepsPulsing() {
        // The preload starts as soon as the app is signed in, and the page can be up before the window
        // has laid itself out — where a stripe that ends with the load is a flash nobody sees. The tail
        // is fixed rather than "the remainder of a minimum", so a load that took longer than the minimum
        // is still followed by one.
        self.playerService.webViewLoadingLingerDuration = 30
        self.playerService.beginWebViewPageLoad()
        self.playerService.finishWebViewPageLoad()

        #expect(self.playerService.isWebViewLoadWarmingUp)
        #expect(self.playerService.webViewPageLoadFraction == nil)
        // Nothing left to measure, so the stripe pulses rather than filling.
        #expect(self.playerService.playerBarLoading?.isIndeterminate == true)
    }

    @Test("A tail of nothing hands the bar straight back")
    func noTailMeansNoStripe() {
        self.playerService.webViewLoadingLingerDuration = 0
        self.playerService.beginWebViewPageLoad()
        self.playerService.finishWebViewPageLoad()

        #expect(self.playerService.isWebViewLoadWarmingUp == false)
        #expect(self.playerService.playerBarLoading == nil)
    }

    @Test("The tail ends by itself")
    func tailExpires() async {
        self.playerService.webViewLoadingLingerDuration = 0.01
        self.playerService.beginWebViewPageLoad()
        self.playerService.finishWebViewPageLoad()
        #expect(self.playerService.isWebViewLoadWarmingUp)

        try? await Task.sleep(for: .milliseconds(150))

        #expect(self.playerService.isWebViewLoadWarmingUp == false)
        #expect(self.playerService.playerBarLoading == nil)
    }

    @Test("Playback starting takes the tail with it")
    func playbackEndsTheTail() {
        self.playerService.webViewLoadingLingerDuration = 30
        self.playerService.state = .loading
        self.playerService.beginWebViewPageLoad()
        self.playerService.finishWebViewPageLoad()
        #expect(self.playerService.playerBarLoading?.isIndeterminate == true)

        // The track the page was loaded for is playing: there is nothing left for the bar to say.
        self.playerService.state = .playing
        #expect(self.playerService.playerBarLoading == nil)
    }

    @Test("A load that ends after playback started leaves no tail behind")
    func playbackEndsTheTailBeforeItStarts() {
        self.playerService.state = .playing
        self.playerService.beginWebViewPageLoad()
        self.playerService.finishWebViewPageLoad()

        #expect(self.playerService.isWebViewLoadWarmingUp == false)
        #expect(self.playerService.playerBarLoading == nil)
    }

    @Test("A new page load takes over from the tail")
    func newLoadReplacesTheTail() {
        self.playerService.webViewLoadingLingerDuration = 30
        self.playerService.beginWebViewPageLoad()
        self.playerService.finishWebViewPageLoad()
        #expect(self.playerService.isWebViewLoadWarmingUp)

        // The next navigation has its own fraction to report, and the pulse belonged to the last one.
        self.playerService.beginWebViewPageLoad()
        #expect(self.playerService.isWebViewLoadWarmingUp == false)
        #expect(self.playerService.playerBarLoading == PlayerBarLoadingIndicator(style: .determinate, fraction: 0))
    }

    @Test("The tail has a default long enough to outlast a window coming up")
    func tailDefault() {
        #expect(PlayerBarLoadingLinger.tail == PlayerService().webViewLoadingLingerDuration)
        #expect(PlayerBarLoadingLinger.tail >= 2)
    }

    @Test("A step too small to draw is dropped, a larger one is published")
    func pageLoadStepsAreQuantized() {
        self.playerService.beginWebViewPageLoad()
        self.playerService.updateWebViewPageLoadProgress(0.5)
        let published = self.playerService.webViewPageLoadFraction

        // WebKit reports `estimatedProgress` on every frame of a load. An observable write per frame
        // redraws everything that reads the player service, for a strip a few points tall.
        self.playerService.updateWebViewPageLoadProgress(0.5 + PlayerService.webViewPageLoadQuantum / 4)
        #expect(self.playerService.webViewPageLoadFraction == published)

        self.playerService.updateWebViewPageLoadProgress(0.5 + PlayerService.webViewPageLoadQuantum)
        let advanced = self.playerService.webViewPageLoadFraction ?? 0
        #expect(abs(advanced - 0.51) < 1e-9)

        // An estimate outside the bar is clamped rather than drawn past its end.
        self.playerService.updateWebViewPageLoadProgress(1.5)
        #expect(self.playerService.webViewPageLoadFraction == 1)
    }

    @Test("A finished load cannot leave a stale fraction behind")
    func finishedLoadClearsTheFraction() {
        self.playerService.beginWebViewPageLoad()
        self.playerService.updateWebViewPageLoadProgress(0.9)
        self.playerService.finishWebViewPageLoad()

        #expect(self.playerService.webViewPageLoadFraction == nil)
    }

    @Test("An estimate arriving after the load ended cannot resurrect the strip")
    func lateEstimateIsIgnored() {
        self.playerService.beginWebViewPageLoad()
        self.playerService.finishWebViewPageLoad()

        // WebKit reports its last estimate (1) in the same turn `didFinish` arrives. Taking it would
        // leave a full strip on the bar until the next navigation.
        self.playerService.updateWebViewPageLoadProgress(1)
        #expect(self.playerService.webViewPageLoadFraction == nil)

        // And a load that never started has nothing to report into either.
        self.playerService.updateWebViewPageLoadProgress(0.5)
        #expect(self.playerService.webViewPageLoadFraction == nil)
    }

    // MARK: - When the player layer is hosted, and when the shell is loaded

    @Test("A signed-in session hosts the player layer so the shell has somewhere to load")
    func hostingRule() {
        #expect(PlayerWebViewPreload.shouldHostPlayerWebView(isSignedIn: true, hasPendingVideo: false))
        #expect(PlayerWebViewPreload.shouldHostPlayerWebView(isSignedIn: false, hasPendingVideo: true))
        #expect(PlayerWebViewPreload.shouldHostPlayerWebView(isSignedIn: true, hasPendingVideo: true))

        // Onboarding: nothing to warm and nothing to play, so no WebView is created at all.
        #expect(PlayerWebViewPreload.shouldHostPlayerWebView(isSignedIn: false, hasPendingVideo: false) == false)
    }

    @Test("A track that is known is the page to have ready, the shell is the fallback")
    func preloadTarget() {
        // A restored session knows its song before anything is played: that is the page the first
        // press of play would otherwise spend seconds loading.
        #expect(PlayerWebViewPreload.target(activeVideoId: "video-1") == .activeSong(videoId: "video-1"))

        // With nothing to be ready for, the shell is the cheapest thing that warms the app.
        #expect(PlayerWebViewPreload.target(activeVideoId: nil) == .shell)
        #expect(PlayerWebViewPreload.target(activeVideoId: "") == .shell)
    }

    @Test("The shell is loaded only into an empty WebView")
    func shellRule() {
        #expect(PlayerWebViewPreload.canLoadShell(currentVideoId: nil, page: .empty))

        // A shell is a placeholder for "no track yet", and is never loaded over a page that has one.
        #expect(PlayerWebViewPreload.canLoadShell(currentVideoId: nil, page: .shell) == false)
        #expect(PlayerWebViewPreload.canLoadShell(currentVideoId: nil, page: .preloaded) == false)
        #expect(PlayerWebViewPreload.canLoadShell(currentVideoId: nil, page: .playback) == false)
        #expect(PlayerWebViewPreload.canLoadShell(currentVideoId: "video-1", page: .empty) == false)
    }

    @Test("A track is preloaded into an empty WebView, or over the shell, and never over a track")
    func preloadRule() {
        #expect(PlayerWebViewPreload.canLoadPreload(currentVideoId: nil, page: .empty))
        // The shell was loaded before the session's track was known; the track is worth more.
        #expect(PlayerWebViewPreload.canLoadPreload(currentVideoId: nil, page: .shell))

        // A page that already has a track in it is never replaced by a preload: preloading exists to
        // be ready, never to change what is on screen.
        #expect(PlayerWebViewPreload.canLoadPreload(currentVideoId: nil, page: .preloaded) == false)
        #expect(PlayerWebViewPreload.canLoadPreload(currentVideoId: nil, page: .playback) == false)
        #expect(PlayerWebViewPreload.canLoadPreload(currentVideoId: "video-1", page: .empty) == false)
        #expect(PlayerWebViewPreload.canLoadPreload(currentVideoId: "video-1", page: .shell) == false)
    }

    @Test("Only a page Kaset is playing from reports, and only the shell and a preload stay quiet")
    func pagePurposes() {
        #expect(PlayerWebViewPage.playback.isAuthoritative)
        #expect(PlayerWebViewPage.shell.isAuthoritative == false)
        #expect(PlayerWebViewPage.preloaded.isAuthoritative == false)
        #expect(PlayerWebViewPage.empty.isAuthoritative == false)

        #expect(PlayerWebViewPage.shell.isSilent)
        #expect(PlayerWebViewPage.preloaded.isSilent)
        #expect(PlayerWebViewPage.playback.isSilent == false)
    }

    @Test("A shell reports nothing, a preload reports only the track it holds, a playing page reports all")
    func pageObservationScopes() {
        #expect(PlayerWebViewPage.empty.observation == .none)
        #expect(PlayerWebViewPage.shell.observation == .none)
        #expect(PlayerWebViewPage.preloaded.observation == .metadata)
        #expect(PlayerWebViewPage.playback.observation == .playback)

        // Authority is the top of that same scale: a page gets to report playback state only by
        // being the page Kaset is playing from.
        for page in [PlayerWebViewPage.empty, .shell, .preloaded, .playback] {
            #expect(page.isAuthoritative == (page.observation == .playback))
        }
    }

    // MARK: - What a preloaded page contributes

    @Test("A preloaded page's observation normalizes the artist and unlocks the lyrics search")
    func preloadedObservationNormalizesArtist() {
        self.playerService.currentTrack = Self.multiArtistSong(videoId: "video-1")
        #expect(self.playerService.hasObservedWebMetadata(for: "video-1") == false)

        // YouTube's localized byline is what the player bar renders; the preload is the first moment a
        // restored session can see how YouTube itself spells the track it is about to resume.
        self.playerService.reconcilePreloadedTrackMetadata(
            title: "A Song",
            artist: "Artist A und Artist B",
            thumbnailUrl: "",
            videoId: "video-1"
        )

        #expect(self.playerService.hasObservedWebMetadata(for: "video-1"))
        #expect(self.playerService.observedWebMetadata?.title == "A Song")
        #expect(self.playerService.observedWebMetadata?.artist == "Artist A, Artist B")
        #expect(self.playerService.lyricsSearchMetadata(for: "video-1")?.artist == "Artist A, Artist B")
    }

    @Test("A preloaded page's observation changes nothing about what is playing")
    func preloadedObservationLeavesPlaybackAlone() {
        self.playerService.currentTrack = Self.multiArtistSong(videoId: "video-1")
        self.playerService.progress = 42
        self.playerService.duration = 200
        self.playerService.state = .paused

        self.playerService.reconcilePreloadedTrackMetadata(
            title: "A Song",
            artist: "Artist A, Artist B",
            thumbnailUrl: "https://example.com/live.jpg",
            videoId: "video-1"
        )

        // A held page has performed nothing: its silence is not a pause and its zero is not a position.
        #expect(self.playerService.progress == 42)
        #expect(self.playerService.duration == 200)
        #expect(self.playerService.state == .paused)

        // The queue stays the authority on the row: structured artists, album and the artwork we
        // already hold all survive the observation.
        #expect(self.playerService.currentTrack?.videoId == "video-1")
        #expect(self.playerService.currentTrack?.artists.count == 2)
        #expect(self.playerService.currentTrack?.album?.title == "An Album")
        #expect(self.playerService.currentTrack?.thumbnailURL?.absoluteString == "https://example.com/art.jpg")
    }

    @Test("A preloaded page corrects an artist line that still carries the album and the year")
    func preloadedObservationCorrectsAShelfRowsByline() {
        // Rows parsed from shelves carry the album and year as extra artist entries, so their display
        // ("SXTN, Leben am Limit, 2017") can never be equivalent to the player-bar byline ("SXTN"). At
        // rest nothing corrected that: pressing play did, by replacing the track with the page's own
        // rendering. The preload *is* that page, so it corrects the bar before the first press.
        self.playerService.currentTrack = Song(
            id: "video-1",
            title: "Staender",
            artists: [
                Artist(id: "artist-sxtn", name: "SXTN"),
                Artist(id: "album-leben-am-limit", name: "Leben am Limit"),
                Artist(id: "year-2017", name: "2017"),
            ],
            album: Album(
                id: "album-1",
                title: "Leben am Limit",
                artists: nil,
                thumbnailURL: nil,
                year: "2017",
                trackCount: nil
            ),
            duration: 180,
            thumbnailURL: URL(string: "https://example.com/art.jpg"),
            videoId: "video-1",
            likeStatus: .like
        )

        self.playerService.reconcilePreloadedTrackMetadata(
            title: "Staender",
            artist: "SXTN",
            thumbnailUrl: "",
            videoId: "video-1"
        )

        // The two strings the player bar renders are the page's, in the casing YouTube reports.
        #expect(self.playerService.currentTrack?.artistsDisplay == "SXTN")
        #expect(self.playerService.currentTrack?.title == "Staender")

        // Everything the queue knows about the row is still there: a page that is only being used for
        // its byline may not cost the album, the length, the artwork or the like state.
        #expect(self.playerService.currentTrack?.album?.title == "Leben am Limit")
        #expect(self.playerService.currentTrack?.duration == 180)
        #expect(self.playerService.currentTrack?.thumbnailURL?.absoluteString == "https://example.com/art.jpg")
        #expect(self.playerService.currentTrack?.likeStatus == .like)
        #expect(self.playerService.currentTrack?.videoId == "video-1")
    }

    @Test("A page that does not say which track it is showing cannot rename the held one")
    func preloadedObservationWithoutAVideoIdKeepsTheHeldByline() {
        self.playerService.currentTrack = Self.multiArtistSong(videoId: "video-1")

        // A page still settling, a shell, an ad: its byline can belong to anything, and the held track
        // is the only thing the app knows is right.
        self.playerService.reconcilePreloadedTrackMetadata(
            title: "Something Else",
            artist: "Someone Else",
            thumbnailUrl: "",
            videoId: nil
        )

        #expect(self.playerService.currentTrack?.title == "A Song")
        #expect(self.playerService.currentTrack?.artistsDisplay == "Artist A, Artist B")
    }

    @Test("A track with no artwork takes the picture the preloaded page rendered")
    func preloadedObservationSuppliesMissingArtwork() {
        self.playerService.currentTrack = Song(
            id: "video-1",
            title: "A Song",
            artists: [Artist(id: "artist-1", name: "Artist A")],
            album: nil,
            duration: 200,
            thumbnailURL: nil,
            videoId: "video-1"
        )

        self.playerService.reconcilePreloadedTrackMetadata(
            title: "A Song",
            artist: "Artist A",
            thumbnailUrl: "https://example.com/player-bar.jpg",
            videoId: "video-1"
        )

        // `fetchSongMetadata` can lose its race against account initialization, and the preload may be
        // the only thing that ever delivers the artwork before the user presses play.
        #expect(self.playerService.currentTrack?.thumbnailURL?.absoluteString == "https://example.com/player-bar.jpg")
    }

    @Test("A preloaded page is ignored when it describes a track Kaset is not holding")
    func preloadedObservationOfAnotherTrackIsIgnored() {
        self.playerService.currentTrack = Self.multiArtistSong(videoId: "video-1")

        self.playerService.reconcilePreloadedTrackMetadata(
            title: "Another Song",
            artist: "Someone Else",
            thumbnailUrl: "https://example.com/other.jpg",
            videoId: "video-2"
        )

        // A page that is not playing does not get to change what the app considers current, and it has
        // not observed the held track either.
        #expect(self.playerService.currentTrack?.videoId == "video-1")
        #expect(self.playerService.currentTrack?.title == "A Song")
        #expect(self.playerService.observedWebMetadata == nil)
    }

    @Test("A half-rendered player bar is not an observation")
    func preloadedObservationNeedsBothParts() {
        self.playerService.currentTrack = Self.multiArtistSong(videoId: "video-1")

        // The lyrics gate waits for a complete observation; ''half a player bar'' must not satisfy it.
        self.playerService.reconcilePreloadedTrackMetadata(
            title: "",
            artist: "Artist A",
            thumbnailUrl: "",
            videoId: "video-1"
        )
        #expect(self.playerService.observedWebMetadata == nil)

        self.playerService.reconcilePreloadedTrackMetadata(
            title: "A Song",
            artist: "",
            thumbnailUrl: "",
            videoId: "video-1"
        )
        #expect(self.playerService.observedWebMetadata == nil)
    }

    /// A two-artist track the WebView will report as "Artist A und Artist B", with the richer fields a
    /// queue row has and a player-bar observation would not.
    private static func multiArtistSong(videoId: String) -> Song {
        Song(
            id: videoId,
            title: "A Song",
            artists: [Artist(id: "artist-1", name: "Artist A"), Artist(id: "artist-2", name: "Artist B")],
            album: Album(
                id: "album-1",
                title: "An Album",
                artists: nil,
                thumbnailURL: nil,
                year: nil,
                trackCount: nil
            ),
            duration: 200,
            thumbnailURL: URL(string: "https://example.com/art.jpg"),
            videoId: videoId
        )
    }

    @Test("A watch URL carries the track, the hold, and the position to resume from")
    func watchURL() {
        let playing = SingletonPlayerWebView.watchURL(videoId: "video-1")
        #expect(playing?.query()?.contains("v=video-1") == true)
        // A page Kaset is playing from carries no hold, and no position it did not ask for.
        #expect(playing?.query()?.contains("kaset_preload") == false)
        #expect(playing?.query()?.contains("t=") == false)

        let preloaded = SingletonPlayerWebView.watchURL(videoId: "video-1", startAt: 120.7, holdsSilent: true)
        #expect(preloaded?.query()?.contains("kaset_preload=1") == true)
        // YouTube's own start position, whole seconds: the page resumes where the session left off.
        #expect(preloaded?.query()?.contains("t=120s") == true)

        // A position that is not meaningfully into the track is not worth a query item.
        let fromStart = SingletonPlayerWebView.watchURL(videoId: "video-1", startAt: 0)
        #expect(fromStart?.query()?.contains("t=") == false)

        #expect(SingletonPlayerWebView.isShellURL(SingletonPlayerWebView.watchURL(videoId: "video-1")) == false)
    }

    @Test("Preloading before there is a WebView claims nothing")
    func preloadWithoutWebViewIsANoOp() {
        // The player layer calls this on every layout pass, including the ones before a WebView can
        // exist. Claiming a page is up while there is nothing to show it in would make the
        // `page` guard drop the first real page's observations.
        SingletonPlayerWebView.shared.loadShellIfNeeded()
        SingletonPlayerWebView.shared.preloadVideo(videoId: "video-1")
        SingletonPlayerWebView.shared.handOverToUser()

        #expect(SingletonPlayerWebView.shared.webView == nil)
        #expect(SingletonPlayerWebView.shared.page == .empty)
        #expect(SingletonPlayerWebView.shared.currentVideoId == nil)
    }

    @Test("Nothing can be played before there is a page, so the track is loaded properly")
    func nothingIsPlayableWithoutAPage() {
        let singleton = SingletonPlayerWebView.shared

        // No page at all: not ready, and nothing to play from. A preload is what the player layer does
        // about that; until it exists, the ordinary load is the only way to start a track.
        #expect(singleton.isPageReady == false)
        #expect(singleton.canPlay(videoId: "video-1") == false)

        self.playerService.pendingPlayVideoId = "video-1"
        #expect(self.playerService.shouldLoadPendingVideoBeforePlayback)
    }

    // MARK: - A restored session's position

    @Test("A deferred session reports the position to preload from")
    func deferredResumePosition() {
        #expect(self.playerService.deferredResumePosition == nil)

        self.playerService.isPendingRestoredLoadDeferred = true
        #expect(self.playerService.deferredResumePosition == nil)

        self.playerService.pendingRestoredSeek = 120
        #expect(self.playerService.deferredResumePosition == 120)

        // The track's opening is not worth a `t=` item, and a resumed session is not deferred once it
        // has been resumed.
        self.playerService.pendingRestoredSeek = 0.4
        #expect(self.playerService.deferredResumePosition == nil)
        self.playerService.pendingRestoredSeek = 120
        self.playerService.isPendingRestoredLoadDeferred = false
        #expect(self.playerService.deferredResumePosition == nil)
    }
}
