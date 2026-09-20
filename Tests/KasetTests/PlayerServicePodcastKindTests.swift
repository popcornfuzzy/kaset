import Foundation
import Testing
@testable import Kaset

/// Tests for the playback-kind classification that decides whether the player bar shows
/// rewind/forward controls instead of previous/next.
///
/// `isCurrentTrackPodcast` is deliberately **not** the same question as `currentEpisode != nil`:
/// - A podcast episode played from a show page is a queued `Song` carrying the `"podcast"` artist
///   marker, and `currentEpisode` stays nil.
/// - `currentEpisode` is only set for standalone artist-page episodes (live streams), which are not
///   podcasts and have no duration to seek within.
@Suite(.serialized, .tags(.service))
@MainActor
struct PlayerServicePodcastKindTests {
    var playerService: PlayerService
    var mockClient: MockYTMusicClient

    init() {
        UserDefaults.standard.removeObject(forKey: "playerVolume")
        UserDefaults.standard.removeObject(forKey: "playerVolumeBeforeMute")
        UserDefaults.standard.removeObject(forKey: "kaset.saved.queue")
        UserDefaults.standard.removeObject(forKey: "kaset.saved.queueIndex")
        UserDefaults.standard.removeObject(forKey: "kaset.saved.playbackSession")
        SingletonPlayerWebView.shared.currentVideoId = nil

        self.mockClient = MockYTMusicClient()
        self.playerService = PlayerService()
        self.playerService.setYTMusicClient(self.mockClient)
    }

    /// Builds the exact `Song` shape `PodcastsView.playEpisode` produces for an episode.
    private static func podcastEpisodeSong(
        videoId: String = "episode-video",
        title: String = "Episode 1",
        showTitle: String = "The Test Show"
    ) -> Song {
        Song(
            id: videoId,
            title: title,
            artists: [Artist(id: "podcast", name: showTitle)],
            album: nil,
            duration: 3600,
            thumbnailURL: nil,
            videoId: videoId
        )
    }

    @Test("A podcast episode queued from a show page is classified as a podcast without an artist episode")
    func queuedPodcastEpisodeIsClassifiedAsPodcast() async {
        let episode = Self.podcastEpisodeSong()

        await self.playerService.playQueue([episode], startingAt: 0)

        #expect(self.playerService.isCurrentTrackPodcast)
        // The player bar must not rely on this being non-nil — it is nil for show-page episodes.
        #expect(self.playerService.currentEpisode == nil)
    }

    @Test("A regular song is not classified as a podcast")
    func regularSongIsNotClassifiedAsPodcast() async {
        let song = Song(
            id: "song-1",
            title: "Song 1",
            artists: [Artist(id: "artist-1", name: "Artist")],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "song-1"
        )

        await self.playerService.playQueue([song], startingAt: 0)

        #expect(!self.playerService.isCurrentTrackPodcast)
        #expect(self.playerService.currentEpisode == nil)
    }

    @Test("Classification is not dropped by metadata that lost the podcast marker")
    func classificationSurvivesMarkerLessMetadataForTheSameEpisode() {
        let episode = Self.podcastEpisodeSong()
        // The WebView's byline never carries the marker, and re-derived tracks report `unknown`
        // as the artist. Reconciling against either must not downgrade the episode.
        let markerlessSameEpisode = Song(
            id: episode.videoId,
            title: episode.title,
            artists: [Artist(id: "unknown", name: "The Test Show")],
            album: nil,
            duration: 3600,
            thumbnailURL: nil,
            videoId: episode.videoId
        )

        self.playerService.updateCurrentPlaybackKind(using: episode)
        #expect(self.playerService.isCurrentTrackPodcast)

        self.playerService.updateCurrentPlaybackKind(using: markerlessSameEpisode)

        // A flip here would swap the transport icons back to previous/next mid-episode.
        #expect(self.playerService.isCurrentTrackPodcast)

        // A genuinely different item still clears it.
        self.playerService.updateCurrentPlaybackKind(using: Song(
            id: "other",
            title: "Other Song",
            artists: [Artist(id: "artist-1", name: "Artist")],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "other"
        ))
        #expect(!self.playerService.isCurrentTrackPodcast)

        // As does losing the item entirely.
        self.playerService.updateCurrentPlaybackKind(using: episode)
        self.playerService.updateCurrentPlaybackKind(using: nil)
        #expect(!self.playerService.isCurrentTrackPodcast)
    }

    @Test("Replaying the same classified episode keeps the podcast classification")
    func replayingTheSameEpisodeKeepsClassification() async {
        let episode = Self.podcastEpisodeSong()
        self.mockClient.songResponses[episode.videoId] = episode
        await self.playerService.playQueue([episode], startingAt: 0)

        #expect(self.playerService.isCurrentTrackPodcast)

        // Queue-drift correction and same-episode restarts call `play(videoId:)`, which cannot know
        // the podcast marker and passes `isPodcast: false`.
        await self.playerService.play(videoId: episode.videoId)

        #expect(self.playerService.isCurrentTrackPodcast)
    }

    @Test("Moving to a different video clears the podcast classification")
    func differentVideoClearsClassification() async {
        let episode = Self.podcastEpisodeSong()
        self.mockClient.songResponses[episode.videoId] = episode
        await self.playerService.playQueue([episode], startingAt: 0)

        #expect(self.playerService.isCurrentTrackPodcast)

        await self.playerService.play(videoId: "some-music-video")

        #expect(!self.playerService.isCurrentTrackPodcast)
    }

    @Test("An artist-page episode keeps currentEpisode set but is not a podcast")
    func artistPageEpisodeIsNotClassifiedAsPodcast() async {
        let episode = ArtistEpisode(videoId: "live-video", title: "24/7 Live Radio", isLive: true)

        await self.playerService.playEpisode(episode)

        #expect(self.playerService.currentEpisode == episode)
        // Not a podcast: live streams have no duration, so the bar keeps the (disabled) track controls.
        #expect(!self.playerService.isCurrentTrackPodcast)
    }
}
