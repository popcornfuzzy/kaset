import Foundation
import Testing
@testable import Kaset

// MARK: - PodcastVideoSlotModelTests

@Suite(.tags(.service))
@MainActor
struct PodcastVideoSlotModelTests {
    @Test("the reported slot frame is kept up to date")
    func recordsSlotFrame() {
        let model = PodcastVideoSlotModel()
        #expect(model.hasSlot == false)

        model.updateSlotFrame(CGRect(x: 40, y: 120, width: 520, height: 292))

        #expect(model.frame == CGRect(x: 40, y: 120, width: 520, height: 292))
        #expect(model.hasSlot)
    }

    @Test("sub-pixel layout churn is ignored")
    func ignoresSubPixelChanges() {
        let model = PodcastVideoSlotModel()
        model.updateSlotFrame(CGRect(x: 40, y: 120, width: 520, height: 292))

        model.updateSlotFrame(CGRect(x: 40.2, y: 120.1, width: 520.3, height: 292.2))

        #expect(model.frame == CGRect(x: 40, y: 120, width: 520, height: 292))
    }

    @Test("clearing drops the slot")
    func clearingDropsSlot() {
        let model = PodcastVideoSlotModel()
        model.updateSlotFrame(CGRect(x: 0, y: 0, width: 400, height: 225))

        model.clearSlot()

        #expect(model.frame == .zero)
        #expect(model.hasSlot == false)
    }

    @Test("the video can be switched off and on again")
    func videoEnabledToggle() {
        let model = PodcastVideoSlotModel()
        #expect(model.isVideoEnabled)

        model.isVideoEnabled = false
        #expect(model.isVideoEnabled == false)

        model.isVideoEnabled = true
        #expect(model.isVideoEnabled)
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
