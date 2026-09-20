import Foundation
import SwiftUI
import Testing
@testable import Kaset

// MARK: - PodcastVideoPreferencesTests

@Suite(.tags(.service))
@MainActor
struct PodcastVideoPreferencesTests {
    @Test("the video can be switched off and on again")
    func videoEnabledToggle() {
        let preferences = PodcastVideoPreferences()
        #expect(preferences.isVideoEnabled)

        preferences.isVideoEnabled = false
        #expect(preferences.isVideoEnabled == false)

        preferences.isVideoEnabled = true
        #expect(preferences.isVideoEnabled)
    }

    @Test("an undeclared slot stays empty instead of resolving to a stale bounds")
    func slotAnchorStartsEmpty() {
        #expect(PodcastVideoSlotAnchor.defaultValue == nil)

        var value: Anchor<CGRect>?
        PodcastVideoSlotAnchor.reduce(value: &value) { nil }

        #expect(value == nil)
    }
}

// MARK: - FullscreenPodcastPresentationTests

@Suite(.serialized, .tags(.service))
@MainActor
struct FullscreenPodcastPresentationTests {
    init() {
        UserDefaults.standard.removeObject(forKey: PlayerService.playbackRateKey)
        UserDefaults.standard.removeObject(forKey: PlayerService.volumeKey)
    }

    @Test("the podcast experience is presented only for podcasts in fullscreen")
    func presentationRequiresPodcastInFullscreen() {
        let player = PlayerService()
        player.currentTrack = Self.song
        #expect(player.isFullscreenPodcastPresented == false)

        player.showFullscreenNowPlaying = true
        #expect(player.isFullscreenPodcastPresented)

        // A song keeps the music experience, even in fullscreen.
        player.currentTrack = TestFixtures.makeSong(id: "song-1", title: "A Song")
        #expect(player.isFullscreenPodcastPresented == false)

        player.showFullscreenNowPlaying = false
        #expect(player.isFullscreenPodcastPresented == false)
    }

    @Test("a video surface exists only when the episode or the player reports video")
    func videoSurfaceRequiresVideo() {
        let player = PlayerService()
        #expect(player.hasVideoSurface == false)

        player.currentTrackHasVideo = true
        #expect(player.hasVideoSurface)
    }

    @Test("playback rate is clamped and persisted")
    func playbackRateIsClampedAndPersisted() {
        let player = PlayerService()
        #expect(player.playbackRate == 1.0)

        player.setPlaybackRate(1.5)
        #expect(player.playbackRate == 1.5)
        #expect(UserDefaults.standard.double(forKey: PlayerService.playbackRateKey) == 1.5)

        player.setPlaybackRate(9)
        #expect(player.playbackRate == PlayerService.maximumPlaybackRate)

        player.setPlaybackRate(0.1)
        #expect(player.playbackRate == PlayerService.minimumPlaybackRate)
    }

    @Test("a saved playback rate is restored, out-of-range values are not")
    func playbackRateRestoration() {
        UserDefaults.standard.set(1.25, forKey: PlayerService.playbackRateKey)
        #expect(PlayerService().playbackRate == 1.25)

        UserDefaults.standard.set(4.0, forKey: PlayerService.playbackRateKey)
        #expect(PlayerService().playbackRate == 1.0)
    }

    private static let song = Song(
        id: "episode-1",
        title: "Episode One",
        artists: [Artist(id: "podcast", name: "Some Show")],
        videoId: "episode-1"
    )
}
