import Foundation
import Testing
@testable import Kaset

/// Tests for fullscreen now-playing and related capability state.
@Suite(.serialized, .tags(.service))
@MainActor
struct VideoSupportTests {
    var playerService: PlayerService

    init() {
        UserDefaults.standard.removeObject(forKey: "playerVolume")
        UserDefaults.standard.removeObject(forKey: "playerVolumeBeforeMute")
        self.playerService = PlayerService()
    }

    @Test("currentTrackHasVideo initially false")
    func currentTrackHasVideoInitiallyFalse() {
        #expect(self.playerService.currentTrackHasVideo == false)
    }

    @Test("showFullscreenNowPlaying initially false")
    func showFullscreenNowPlayingInitiallyFalse() {
        #expect(self.playerService.showFullscreenNowPlaying == false)
    }

    @Test("updateVideoAvailability sets hasVideo correctly")
    func updateVideoAvailabilitySetsHasVideo() {
        self.playerService.updateVideoAvailability(hasVideo: true)
        #expect(self.playerService.currentTrackHasVideo == true)

        self.playerService.updateVideoAvailability(hasVideo: false)
        #expect(self.playerService.currentTrackHasVideo == false)
    }

    @Test("fullscreen now playing can be enabled even when hasVideo is false")
    func fullscreenCanBeEnabledWhenNoVideo() {
        #expect(self.playerService.currentTrackHasVideo == false)
        self.playerService.showFullscreenNowPlaying = true
        #expect(self.playerService.showFullscreenNowPlaying == true)
    }

    @Test("fullscreen now playing stays enabled when hasVideo changes")
    func fullscreenStaysEnabledWhenHasVideoChanges() {
        self.playerService.showFullscreenNowPlaying = true
        self.playerService.updateVideoAvailability(hasVideo: false)
        #expect(self.playerService.showFullscreenNowPlaying == true)
    }

    @Test("enabling fullscreen closes lyrics and queue")
    func enablingFullscreenClosesPanels() {
        self.playerService.showLyrics = true
        self.playerService.showQueue = true
        self.playerService.showFullscreenNowPlaying = true

        #expect(self.playerService.showFullscreenNowPlaying == true)
        #expect(self.playerService.showLyrics == false)
        #expect(self.playerService.showQueue == false)
    }

    @Test("enabling lyrics closes fullscreen")
    func enablingLyricsClosesFullscreen() {
        self.playerService.showFullscreenNowPlaying = true
        self.playerService.showLyrics = true

        #expect(self.playerService.showLyrics == true)
        #expect(self.playerService.showFullscreenNowPlaying == false)
    }

    @Test("enabling queue closes fullscreen")
    func enablingQueueClosesFullscreen() {
        self.playerService.showFullscreenNowPlaying = true
        self.playerService.showQueue = true

        #expect(self.playerService.showQueue == true)
        #expect(self.playerService.showFullscreenNowPlaying == false)
    }

    @Test("Song.hasVideo property exists and defaults to nil")
    func songHasVideoPropertyExists() {
        let song = Song(
            id: "test",
            title: "Test Song",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "test-video"
        )
        #expect(song.hasVideo == nil)
    }

    @Test("Song.hasVideo can be set explicitly")
    func songHasVideoCanBeSet() {
        let songWithVideo = Song(
            id: "test",
            title: "Test Song",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "test-video",
            hasVideo: true
        )
        #expect(songWithVideo.hasVideo == true)

        let songWithoutVideo = Song(
            id: "test2",
            title: "Test Song 2",
            artists: [],
            album: nil,
            duration: 180,
            thumbnailURL: nil,
            videoId: "test-video-2",
            hasVideo: false
        )
        #expect(songWithoutVideo.hasVideo == false)
    }
}
