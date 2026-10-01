import Foundation
import Testing
@testable import Kaset

/// Tests for `SongVariantMatcher`.
@Suite(.serialized, .tags(.service))
@MainActor
struct SongVariantMatcherTests {
    private func makeSong(
        videoId: String,
        title: String,
        artist: String = "Test Artist",
        duration: TimeInterval? = 200,
        musicVideoType: MusicVideoType? = nil,
        counterpart: SongCounterpart? = nil
    ) -> Song {
        Song(
            id: videoId,
            title: title,
            artists: [Artist(id: "UC-\(artist)", name: artist)],
            album: nil,
            duration: duration,
            thumbnailURL: nil,
            videoId: videoId,
            musicVideoType: musicVideoType,
            counterpart: counterpart
        )
    }

    // MARK: - Selection

    @Test("Video with an audio counterpart resolves to the audio song")
    func audioPreferredFromVideo() {
        let audio = self.makeSong(
            videoId: "audio-id", title: "Song", musicVideoType: .atv
        )
        let video = self.makeSong(
            videoId: "video-id", title: "Song", musicVideoType: .omv,
            counterpart: SongCounterpart(song: audio)
        )

        let matcher = SongVariantMatcher()
        let preferred = matcher.audioPreferred(video)

        #expect(preferred.videoId == "audio-id")
        #expect(preferred.counterpart?.videoId == "video-id")
    }

    @Test("Song with a video counterpart stays the song and keeps the video")
    func audioPreferredFromSong() {
        let video = self.makeSong(videoId: "video-id", title: "Song", musicVideoType: .omv)
        let audio = self.makeSong(
            videoId: "audio-id", title: "Song", musicVideoType: .atv,
            counterpart: SongCounterpart(song: video)
        )

        let matcher = SongVariantMatcher()
        let preferred = matcher.audioPreferred(audio)

        #expect(preferred.videoId == "audio-id")
        #expect(preferred.counterpart?.videoId == "video-id")
        #expect(matcher.videoVariant(of: preferred)?.videoId == "video-id")
    }

    @Test("Video without a counterpart is left alone")
    func audioPreferredWithoutCounterpart() {
        let video = self.makeSong(videoId: "video-id", title: "Song", musicVideoType: .omv)
        let matcher = SongVariantMatcher()

        let preferred = matcher.audioPreferred(video)

        #expect(preferred.videoId == "video-id")
        #expect(preferred.counterpart == nil)
        #expect(matcher.videoVariant(of: preferred)?.videoId == "video-id")
    }

    @Test("Plain song has no video variant")
    func plainSongHasNoVideo() {
        let song = self.makeSong(videoId: "audio-id", title: "Song", musicVideoType: .atv)
        let matcher = SongVariantMatcher()

        #expect(matcher.videoVariant(of: song) == nil)
    }

    @Test("Normalize collapses a song and its video into one audio entry")
    func normalizeCollapsesVariants() {
        let audio = self.makeSong(videoId: "audio-id", title: "Song", musicVideoType: .atv)
        let video = self.makeSong(
            videoId: "video-id", title: "Song", musicVideoType: .omv,
            counterpart: SongCounterpart(song: audio)
        )
        let pairedAudio = audio.paired(with: video)
        let other = self.makeSong(videoId: "other-id", title: "Other", musicVideoType: .atv)

        let matcher = SongVariantMatcher()
        let normalized = matcher.normalize([video, pairedAudio, other])

        #expect(normalized.map(\.videoId) == ["audio-id", "other-id"])
    }

    // MARK: - Search matching

    @Test("Best match requires a confident title, artist and duration")
    func bestAudioMatchScores() {
        let target = self.makeSong(
            videoId: "video-id", title: "Never Gonna Give You Up",
            artist: "Rick Astley", duration: 214, musicVideoType: .omv
        )
        let exact = self.makeSong(
            videoId: "audio-id", title: "Never Gonna Give You Up",
            artist: "Rick Astley", duration: 214, musicVideoType: .atv
        )
        let cover = self.makeSong(
            videoId: "cover-id", title: "Never Gonna Give You Up",
            artist: "Some Cover Band", duration: 214, musicVideoType: .atv
        )
        let videoCandidate = self.makeSong(
            videoId: "another-video", title: "Never Gonna Give You Up",
            artist: "Rick Astley", duration: 214, musicVideoType: .omv
        )

        let match = SongVariantMatcher.bestAudioMatch(
            for: target, candidates: [cover, videoCandidate, exact]
        )

        #expect(match?.videoId == "audio-id")
    }

    @Test("Best match rejects a cover by a different artist")
    func bestAudioMatchRejectsCover() {
        let target = self.makeSong(
            videoId: "video-id", title: "Wonderwall",
            artist: "Oasis", duration: 259, musicVideoType: .omv
        )
        let cover = self.makeSong(
            videoId: "cover-id", title: "Wonderwall",
            artist: "Karaoke Kings", duration: 259, musicVideoType: .atv
        )

        #expect(SongVariantMatcher.bestAudioMatch(for: target, candidates: [cover]) == nil)
    }

    @Test("Normalized title drops brackets and video qualifiers")
    func normalizedTitleStripsNoise() {
        #expect(
            SongVariantMatcher.normalizedTitle("Wonderwall (Official Video)") == "wonderwall"
        )
        #expect(
            SongVariantMatcher.normalizedTitle("Song [HD] [4K]") == "song"
        )
    }

    @Test("Search query combines title and primary artist")
    func searchQueryUsesArtist() {
        let song = self.makeSong(
            videoId: "video-id", title: "Song (Official Video)",
            artist: "Artist", musicVideoType: .omv
        )
        #expect(SongVariantMatcher.searchQuery(for: song) == "Song Artist")
    }

    @Test("Resolution backfills a video from filtered search")
    func resolvesViaSearch() async throws {
        let video = self.makeSong(
            videoId: "video-id", title: "Song",
            artist: "Artist", duration: 200, musicVideoType: .omv
        )
        let audio = self.makeSong(
            videoId: "audio-id", title: "Song",
            artist: "Artist", duration: 200, musicVideoType: .atv
        )
        let client = MockYTMusicClient()
        client.searchResponse = SearchResponse(songs: [audio], albums: [], artists: [], playlists: [])

        let matcher = SongVariantMatcher()
        let resolved = await matcher.resolveAudioVariant(for: video, client: client)

        #expect(resolved?.videoId == "audio-id")
        #expect(matcher.audioPreferred(video).videoId == "audio-id")
        #expect(client.searchQueries.contains("Song Artist"))
    }
}
