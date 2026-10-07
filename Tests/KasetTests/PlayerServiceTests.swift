import Foundation
import Testing
@testable import Kaset

/// Tests for PlayerService.
@Suite(.serialized, .tags(.service))
@MainActor
struct PlayerServiceTests {
    var playerService: PlayerService

    init() {
        // Reset UserDefaults to ensure clean initial state for tests
        UserDefaults.standard.removeObject(forKey: "playerVolume")
        UserDefaults.standard.removeObject(forKey: "playerVolumeBeforeMute")
        self.playerService = PlayerService()
    }

    // MARK: - Initial State Tests

    @Test("Initial state is idle")
    func initialState() {
        #expect(self.playerService.state == .idle)
        #expect(self.playerService.currentTrack == nil)
        #expect(self.playerService.isPlaying == false)
        #expect(self.playerService.progress == 0)
        #expect(self.playerService.duration == 0)
        #expect(self.playerService.volume == 1.0)
    }

    @Test("isPlaying property")
    func isPlayingProperty() {
        #expect(self.playerService.isPlaying == false)
    }

    // MARK: - PlaybackState Tests

    @Test("PlaybackState equality")
    func playbackStateEquatable() {
        let state1 = PlayerService.PlaybackState.playing
        let state2 = PlayerService.PlaybackState.playing
        #expect(state1 == state2)

        let state3 = PlayerService.PlaybackState.paused
        #expect(state1 != state3)

        let error1 = PlayerService.PlaybackState.error("Test error")
        let error2 = PlayerService.PlaybackState.error("Test error")
        #expect(error1 == error2)

        let error3 = PlayerService.PlaybackState.error("Different error")
        #expect(error1 != error3)
    }

    @Test(
        "PlaybackState isPlaying returns correct value",
        arguments: [
            (PlayerService.PlaybackState.playing, true),
            (PlayerService.PlaybackState.paused, false),
            (PlayerService.PlaybackState.idle, false),
            (PlayerService.PlaybackState.loading, false),
            (PlayerService.PlaybackState.buffering, false),
            (PlayerService.PlaybackState.ended, false),
            (PlayerService.PlaybackState.error("test"), false),
        ]
    )
    func playbackStateIsPlaying(state: PlayerService.PlaybackState, expected: Bool) {
        #expect(state.isPlaying == expected)
    }

    // MARK: - Queue Tests

    @Test("Queue initially empty")
    func queueInitiallyEmpty() {
        #expect(self.playerService.queue.isEmpty)
        #expect(self.playerService.currentIndex == 0)
    }

    @Test("Update playback state to playing")
    func updatePlaybackState() {
        self.playerService.updatePlaybackState(isPlaying: true, progress: 30.0, duration: 180.0)

        #expect(self.playerService.state == .playing)
        #expect(self.playerService.progress == 30.0)
        #expect(self.playerService.duration == 180.0)
        #expect(self.playerService.isPlaying == true)
    }

    @Test("Update playback state to paused")
    func updatePlaybackStatePaused() {
        self.playerService.updatePlaybackState(isPlaying: true, progress: 30.0, duration: 180.0)
        #expect(self.playerService.state == .playing)

        self.playerService.updatePlaybackState(isPlaying: false, progress: 30.0, duration: 180.0)
        #expect(self.playerService.state == .paused)
        #expect(self.playerService.isPlaying == false)
    }

    @Test("Update track metadata")
    func updateTrackMetadata() {
        self.playerService.updateTrackMetadata(
            title: "Test Song",
            artist: "Test Artist",
            thumbnailUrl: "https://example.com/thumb.jpg",
            videoId: nil
        )

        #expect(self.playerService.currentTrack != nil)
        #expect(self.playerService.currentTrack?.title == "Test Song")
        #expect(self.playerService.currentTrack?.artistsDisplay == "Test Artist")
        #expect(self.playerService.currentTrack?.thumbnailURL?.absoluteString == "https://example.com/thumb.jpg")
    }

    @Test("Update track metadata with empty thumbnail")
    func updateTrackMetadataWithEmptyThumbnail() {
        self.playerService.updateTrackMetadata(
            title: "Test Song",
            artist: "Test Artist",
            thumbnailUrl: "",
            videoId: nil
        )

        #expect(self.playerService.currentTrack != nil)
        #expect(self.playerService.currentTrack?.title == "Test Song")
        #expect(self.playerService.currentTrack?.thumbnailURL == nil)
    }

    @Test("Playing the video that is already visible keeps its artwork")
    func playVideoIdKeepsVisibleArtwork() async {
        let artworkURL = URL(string: "https://example.com/visible-artwork.jpg")!
        let song = Song(
            id: "replay-video",
            title: "Replay Song",
            artists: [Artist(id: "artist-1", name: "Artist")],
            duration: 180,
            thumbnailURL: artworkURL,
            videoId: "replay-video"
        )
        await self.playerService.playQueue([song], startingAt: 0)
        #expect(self.playerService.currentTrack?.thumbnailURL == artworkURL)

        // `play(videoId:)` seeds a placeholder track. Dropping the thumbnail here blanked the
        // now-playing artwork until the metadata fetch answered (or never, when it failed).
        await self.playerService.play(videoId: song.videoId)

        #expect(self.playerService.currentTrack?.title == "Loading...")
        #expect(self.playerService.currentTrack?.thumbnailURL == artworkURL)
    }

    @Test("Playing a queued video seeds its artwork from the queue")
    func playVideoIdSeedsArtworkFromQueue() async {
        let queuedArtworkURL = URL(string: "https://example.com/queued-artwork.jpg")!
        let songs = [
            Song(id: "first-video", title: "First Song", artists: [], duration: 180, thumbnailURL: nil, videoId: "first-video"),
            Song(
                id: "second-video",
                title: "Second Song",
                artists: [],
                duration: 200,
                thumbnailURL: queuedArtworkURL,
                videoId: "second-video"
            ),
        ]
        await self.playerService.playQueue(songs, startingAt: 0)

        await self.playerService.play(videoId: "second-video")

        #expect(self.playerService.currentTrack?.videoId == "second-video")
        #expect(self.playerService.currentTrack?.thumbnailURL == queuedArtworkURL)
    }

    @Test("Update ad playback state")
    func updateAdPlaybackState() {
        #expect(self.playerService.isAdPlaying == false)

        self.playerService.updateAdPlaybackState(true)
        #expect(self.playerService.isAdPlaying == true)

        self.playerService.updateAdPlaybackState(false)
        #expect(self.playerService.isAdPlaying == false)
    }

    @Test("Confirm playback started")
    func confirmPlaybackStarted() {
        self.playerService.showMiniPlayer = true
        self.playerService.confirmPlaybackStarted()

        #expect(self.playerService.showMiniPlayer == false)
        #expect(self.playerService.state == .playing)
    }

    @Test("Mini player dismissed")
    func miniPlayerDismissed() {
        self.playerService.showMiniPlayer = true
        self.playerService.miniPlayerDismissed()

        #expect(self.playerService.showMiniPlayer == false)
    }

    // MARK: - Shuffle and Repeat Mode Tests

    @Test("Toggle shuffle")
    func toggleShuffle() {
        #expect(self.playerService.shuffleEnabled == false)

        self.playerService.toggleShuffle()
        #expect(self.playerService.shuffleEnabled == true)

        self.playerService.toggleShuffle()
        #expect(self.playerService.shuffleEnabled == false)
    }

    @Test("Cycle repeat mode")
    func cycleRepeatMode() {
        #expect(self.playerService.repeatMode == .off)

        self.playerService.cycleRepeatMode()
        #expect(self.playerService.repeatMode == .all)

        self.playerService.cycleRepeatMode()
        #expect(self.playerService.repeatMode == .one)

        self.playerService.cycleRepeatMode()
        #expect(self.playerService.repeatMode == .off)
    }

    // MARK: - Volume Tests

    @Test("Is muted initially false")
    func isMuted() {
        #expect(self.playerService.isMuted == false)
    }

    @Test("Initial volume is 1.0")
    func initialVolume() {
        #expect(self.playerService.volume == 1.0)
    }

    // MARK: - Queue Tests

    @Test("Play queue sets queue")
    func playQueueSetsQueue() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await playerService.playQueue(songs, startingAt: 0)

        #expect(self.playerService.queue.count == 3)
        #expect(self.playerService.currentIndex == 0)
    }

    @Test("Play queue starting at index")
    func playQueueStartingAtIndex() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await playerService.playQueue(songs, startingAt: 2)

        #expect(self.playerService.currentIndex == 2)
    }

    @Test("Play queue with invalid index clamps to valid range")
    func playQueueWithInvalidIndex() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
        ]

        await playerService.playQueue(songs, startingAt: 10)

        #expect(self.playerService.currentIndex == 0)
    }

    @Test("Play empty queue does nothing")
    func playQueueEmptyDoesNothing() async {
        await self.playerService.playQueue([], startingAt: 0)
        #expect(self.playerService.queue.isEmpty)
    }

    // MARK: - User Interaction Tests

    @Test("hasUserInteractedThisSession initially false")
    func hasUserInteractedThisSessionInitiallyFalse() {
        #expect(self.playerService.hasUserInteractedThisSession == false)
    }

    @Test("confirmPlaybackStarted sets userInteracted")
    func confirmPlaybackStartedSetsUserInteracted() {
        #expect(self.playerService.hasUserInteractedThisSession == false)
        self.playerService.confirmPlaybackStarted()
        #expect(self.playerService.hasUserInteractedThisSession == true)
    }

    // MARK: - Pending Play Video Tests

    @Test("pendingPlayVideoId initially nil")
    func pendingPlayVideoIdInitiallyNil() {
        #expect(self.playerService.pendingPlayVideoId == nil)
    }

    // MARK: - Mini Player State Tests

    @Test("Mini player initially hidden")
    func miniPlayerInitiallyHidden() {
        #expect(self.playerService.showMiniPlayer == false)
    }

    @Test("Playing podcast song auto-opens mini player")
    func playingPodcastSongAutoOpensMiniPlayer() async {
        let podcast = Song(
            id: "pod-1",
            title: "Episode 1",
            artists: [Artist(id: "podcast", name: "Test Show")],
            album: nil,
            duration: 1200,
            thumbnailURL: nil,
            videoId: "pod-1"
        )

        await self.playerService.play(song: podcast)

        #expect(self.playerService.showMiniPlayer == true)
        #expect(self.playerService.shouldAutoDismissMiniPlayerOnPlaybackStart == false)
    }

    @Test("Playing normal song keeps mini player hidden by default")
    func playingNormalSongKeepsMiniPlayerHiddenByDefault() async {
        let song = Song(
            id: "song-1",
            title: "Song 1",
            artists: [Artist(id: "artist-1", name: "Artist")],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "song-1"
        )

        await self.playerService.play(song: song)

        #expect(self.playerService.showMiniPlayer == false)
    }

    @Test("Manual mini player toggle is available but normal-song track changes still auto-hide")
    func manualMiniPlayerToggleDoesNotOverrideNormalSongAutoHideAcrossTrackChanges() async {
        let firstSong = Song(
            id: "song-1",
            title: "Song 1",
            artists: [Artist(id: "artist-1", name: "Artist")],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "song-1"
        )
        let secondSong = Song(
            id: "song-2",
            title: "Song 2",
            artists: [Artist(id: "artist-2", name: "Artist 2")],
            album: nil,
            duration: 200,
            thumbnailURL: nil,
            videoId: "song-2"
        )

        await self.playerService.play(song: firstSong)
        #expect(self.playerService.showMiniPlayer == false)

        self.playerService.toggleMiniPlayerVisibilityByUser()
        #expect(self.playerService.showMiniPlayer == true)
        #expect(self.playerService.miniPlayerEnabledByUser == true)

        await self.playerService.play(song: secondSong)
        #expect(self.playerService.showMiniPlayer == false)
        #expect(self.playerService.miniPlayerEnabledByUser == false)

        self.playerService.toggleMiniPlayerVisibilityByUser()
        #expect(self.playerService.showMiniPlayer == true)
    }

    @Test("Switching from podcast to song auto-closes mini player")
    func switchingFromPodcastToSongAutoClosesMiniPlayer() async {
        let podcast = Song(
            id: "pod-1",
            title: "Episode 1",
            artists: [Artist(id: "podcast", name: "Test Show")],
            album: nil,
            duration: 1200,
            thumbnailURL: nil,
            videoId: "pod-1"
        )
        let song = Song(
            id: "song-1",
            title: "Song 1",
            artists: [Artist(id: "artist-1", name: "Artist")],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "song-1"
        )

        await self.playerService.play(song: podcast)
        #expect(self.playerService.showMiniPlayer == true)

        await self.playerService.play(song: song)
        #expect(self.playerService.showMiniPlayer == false)
    }

    @Test("Video dimensions update mini player aspect ratio")
    func videoDimensionsUpdateMiniPlayerAspectRatio() {
        #expect(self.playerService.miniPlayerVideoAspectRatio == nil)

        self.playerService.updateMiniPlayerVideoDimensions(width: 1920, height: 1080)

        #expect(self.playerService.miniPlayerVideoAspectRatio != nil)
        #expect(self.playerService.miniPlayerVideoAspectRatio == (1920.0 / 1080.0))
    }

    @Test("Invalid video dimensions are ignored")
    func invalidVideoDimensionsAreIgnored() {
        self.playerService.updateMiniPlayerVideoDimensions(width: 1280, height: 720)
        let previousRatio = self.playerService.miniPlayerVideoAspectRatio

        self.playerService.updateMiniPlayerVideoDimensions(width: 0, height: 720)
        #expect(self.playerService.miniPlayerVideoAspectRatio == previousRatio)

        self.playerService.updateMiniPlayerVideoDimensions(width: 4000, height: 1)
        #expect(self.playerService.miniPlayerVideoAspectRatio == previousRatio)
    }

    // MARK: - Queue/Lyrics Mutual Exclusivity Tests

    @Test("showQueue initially false")
    func showQueueInitiallyFalse() {
        #expect(self.playerService.showQueue == false)
    }

    @Test("showLyrics initially false")
    func showLyricsInitiallyFalse() {
        #expect(self.playerService.showLyrics == false)
    }

    @Test("Show queue closes lyrics")
    func showQueueClosesLyrics() {
        self.playerService.showLyrics = true
        #expect(self.playerService.showLyrics == true)
        #expect(self.playerService.showQueue == false)

        self.playerService.showQueue = true
        #expect(self.playerService.showQueue == true)
        #expect(self.playerService.showLyrics == false, "Opening queue should close lyrics")
    }

    @Test("Show lyrics closes queue")
    func showLyricsClosesQueue() {
        self.playerService.showQueue = true
        #expect(self.playerService.showQueue == true)
        #expect(self.playerService.showLyrics == false)

        self.playerService.showLyrics = true
        #expect(self.playerService.showLyrics == true)
        #expect(self.playerService.showQueue == false, "Opening lyrics should close queue")
    }

    @Test("Both sidebars can be closed")
    func bothSidebarsCanBeClosed() {
        self.playerService.showQueue = true
        #expect(self.playerService.showQueue == true)

        self.playerService.showQueue = false
        #expect(self.playerService.showQueue == false)
        #expect(self.playerService.showLyrics == false)
    }

    // MARK: - Now Playing Sidebar Tests

    @Test("The launch state of the column follows which sidebar design is enabled")
    func sidebarLaunchStateFollowsEnabledDesign() {
        let previous = SettingsManager.shared.nowPlayingSidebarEnabled
        defer { SettingsManager.shared.nowPlayingSidebarEnabled = previous }

        // A reader on the classic panels gets a closed column at launch.
        SettingsManager.shared.nowPlayingSidebarEnabled = false
        let classic = PlayerService()
        #expect(classic.nowPlayingSidebarPage == nil)
        #expect(classic.isNowPlayingSidebarVisible == false)

        // The sidebar design is the default, so the column is already open — before the window's
        // first layout, which is why `PlayerService.init` states it rather than `MainWindow`.
        SettingsManager.shared.nowPlayingSidebarEnabled = true
        let sidebar = PlayerService()
        #expect(sidebar.nowPlayingSidebarPage == .overview)
        #expect(sidebar.isNowPlayingSidebarVisible)
    }

    @Test("First press opens the sidebar overview, the second expands the requested page")
    func toggleNowPlayingSidebarExpandsFromOverview() {
        // The button's state machine starts from a closed column, whichever design launched it.
        self.playerService.closeNowPlayingSidebar()

        self.playerService.toggleNowPlayingSidebar(page: .lyrics)
        #expect(self.playerService.nowPlayingSidebarPage == .overview)

        self.playerService.toggleNowPlayingSidebar(page: .lyrics)
        #expect(self.playerService.nowPlayingSidebarPage == .lyrics)

        // The same button collapses back to the overview rather than hiding the panel.
        self.playerService.toggleNowPlayingSidebar(page: .lyrics)
        #expect(self.playerService.nowPlayingSidebarPage == .overview)
    }

    @Test("Each transport button switches to its own page while the sidebar is open")
    func toggleNowPlayingSidebarSwitchesPages() {
        self.playerService.closeNowPlayingSidebar()

        self.playerService.toggleNowPlayingSidebar(page: .lyrics)
        self.playerService.toggleNowPlayingSidebar(page: .lyrics)
        #expect(self.playerService.nowPlayingSidebarPage == .lyrics)

        self.playerService.toggleNowPlayingSidebar(page: .queue)
        #expect(self.playerService.nowPlayingSidebarPage == .queue)

        self.playerService.toggleNowPlayingSidebar(page: .lyrics)
        #expect(self.playerService.nowPlayingSidebarPage == .lyrics)
    }

    @Test("The sidebar closes explicitly")
    func closeNowPlayingSidebar() {
        self.playerService.setNowPlayingSidebarPage(.queue)
        #expect(self.playerService.isNowPlayingSidebarVisible)

        self.playerService.closeNowPlayingSidebar()
        #expect(self.playerService.nowPlayingSidebarPage == nil)
        #expect(self.playerService.isNowPlayingSidebarVisible == false)
    }

    @Test("Opening the Now Playing sidebar closes the classic panels")
    func nowPlayingSidebarClosesClassicPanels() {
        self.playerService.showLyrics = true

        self.playerService.setNowPlayingSidebarPage(.overview)

        #expect(self.playerService.showLyrics == false)
        #expect(self.playerService.showQueue == false)
        #expect(self.playerService.nowPlayingSidebarPage == .overview)
    }

    @Test("Opening a classic panel closes the Now Playing sidebar")
    func classicPanelsCloseNowPlayingSidebar() {
        self.playerService.setNowPlayingSidebarPage(.overview)

        self.playerService.showQueue = true

        #expect(self.playerService.showQueue == true)
        #expect(self.playerService.nowPlayingSidebarPage == nil)
    }

    @Test("Fullscreen now playing leaves the Now Playing sidebar open")
    func fullscreenLeavesNowPlayingSidebarOpen() {
        self.playerService.setNowPlayingSidebarPage(.lyrics)

        self.playerService.showFullscreenNowPlaying = true

        // The player covers the window, so the column behind it is out of sight either way. Closing it
        // here would change the reader's window layout from a view they did not touch — and would give
        // the presentation a window operation to perform in the same turn it was being put up.
        #expect(self.playerService.nowPlayingSidebarPage == .lyrics)

        self.playerService.showFullscreenNowPlaying = false

        #expect(self.playerService.nowPlayingSidebarPage == .lyrics)
    }

    @Test("Opening the Now Playing sidebar exits fullscreen")
    func nowPlayingSidebarExitsFullscreen() {
        self.playerService.showFullscreenNowPlaying = true

        self.playerService.setNowPlayingSidebarPage(.queue)

        #expect(self.playerService.showFullscreenNowPlaying == false)
        #expect(self.playerService.nowPlayingSidebarPage == .queue)
    }

    @Test("Transport button active state follows whichever sidebar design is enabled")
    func panelActiveStateFollowsSidebarStyle() {
        let previous = SettingsManager.shared.nowPlayingSidebarEnabled
        defer { SettingsManager.shared.nowPlayingSidebarEnabled = previous }

        // Classic design: the buttons follow the classic panels.
        SettingsManager.shared.nowPlayingSidebarEnabled = false
        self.playerService.showLyrics = true
        #expect(self.playerService.isLyricsPanelActive)
        #expect(self.playerService.isQueuePanelActive == false)

        self.playerService.showLyrics = false

        // Now Playing design: the overview lights neither button, each page lights its own.
        SettingsManager.shared.nowPlayingSidebarEnabled = true
        self.playerService.setNowPlayingSidebarPage(.overview)
        #expect(self.playerService.isLyricsPanelActive == false)
        #expect(self.playerService.isQueuePanelActive == false)

        self.playerService.setNowPlayingSidebarPage(.queue)
        #expect(self.playerService.isQueuePanelActive)
        #expect(self.playerService.isLyricsPanelActive == false)
    }

    // MARK: - Clear Queue Tests

    @Test("Clear queue with no current track")
    func clearQueueWithNoCurrentTrack() {
        self.playerService.clearQueue()

        #expect(self.playerService.queue.isEmpty)
        #expect(self.playerService.currentIndex == 0)
    }

    @Test("Clear queue keeps current track")
    func clearQueueKeepsCurrentTrack() async {
        let songs = [
            Song(id: "1", title: "Song 1", artists: [], album: nil, duration: 180, thumbnailURL: nil, videoId: "v1"),
            Song(id: "2", title: "Song 2", artists: [], album: nil, duration: 200, thumbnailURL: nil, videoId: "v2"),
            Song(id: "3", title: "Song 3", artists: [], album: nil, duration: 220, thumbnailURL: nil, videoId: "v3"),
        ]

        await playerService.playQueue(songs, startingAt: 1)

        self.playerService.clearQueue()

        #expect(self.playerService.queue.count == 1)
        #expect(self.playerService.queue.first?.videoId == "v2")
        #expect(self.playerService.currentIndex == 0)
    }
}
