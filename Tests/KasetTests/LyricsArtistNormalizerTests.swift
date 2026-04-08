import Testing
@testable import Kaset

@Suite(.tags(.service))
struct LyricsArtistNormalizerTests {
    @Test("normalizes localized conjunctions")
    func normalizesLocalizedConjunctions() {
        let normalizedGerman = LyricsArtistNormalizer.normalizeForSearch("Artist A und Artist B")
        let normalizedFrench = LyricsArtistNormalizer.normalizeForSearch("Artist A et Artist B")
        let normalizedSpanish = LyricsArtistNormalizer.normalizeForSearch("Artist A y Artist B")
        let normalizedAmpersand = LyricsArtistNormalizer.normalizeForSearch("Artist A & Artist B")

        #expect(normalizedGerman == "artist a and artist b")
        #expect(normalizedFrench == "artist a and artist b")
        #expect(normalizedSpanish == "artist a and artist b")
        #expect(normalizedAmpersand == "artist a and artist b")
    }

    @Test("removes year in parentheses from artist")
    func removesYearSuffix() {
        let normalized = LyricsArtistNormalizer.normalizeForSearch("The Beatles (1967)")
        #expect(normalized == "the beatles")
    }

    @Test("extracts normalized artist components")
    func extractsArtistComponents() {
        let components = LyricsArtistNormalizer.artistComponents("Artist A und Artist B, Artist C")
        #expect(components == ["artist a", "artist b", "artist c"])
    }

    @Test("removes official video labels from title")
    func removesOfficialVideoLabelsFromTitle() {
        #expect(LyricsArtistNormalizer.normalizeTitleForSearch("Song Name (Official Video)") == "song name")
        #expect(LyricsArtistNormalizer.normalizeTitleForSearch("Song Name (Video)") == "song name")
        #expect(LyricsArtistNormalizer.normalizeTitleForSearch("Song Name (Official Lyric Video)") == "song name")
        #expect(LyricsArtistNormalizer.normalizeTitleForSearch("Song Name (Official Visualizer)") == "song name")
    }
}

@Suite(.tags(.service))
struct LRCLibProviderSelectionTests {
    @Test("prefers better artist match over slightly closer duration")
    func prefersArtistMatchBeforeDurationTieBreaker() {
        let info = LyricsSearchInfo(
            title: "Song",
            artist: "Artist A und Artist B",
            album: nil,
            duration: 180,
            videoId: "video-id"
        )

        let closerDurationWrongArtist = LRCLibModel(
            id: 1,
            trackName: "Song",
            artistName: "Different Artist",
            albumName: nil,
            duration: 180,
            instrumental: false,
            plainLyrics: "Plain",
            syncedLyrics: nil
        )

        let slightlyOffDurationCorrectArtist = LRCLibModel(
            id: 2,
            trackName: "Song",
            artistName: "Artist A and Artist B",
            albumName: nil,
            duration: 185,
            instrumental: false,
            plainLyrics: "Plain",
            syncedLyrics: "[00:00.00]Line"
        )

        let selected = LRCLibProvider.selectBestMatch(
            from: [closerDurationWrongArtist, slightlyOffDurationCorrectArtist],
            info: info
        )

        #expect(selected.id == 2)
    }

    @Test("keeps duration behavior when artist data is empty")
    func fallsBackToDurationWhenArtistUnavailable() {
        let info = LyricsSearchInfo(
            title: "Song",
            artist: "",
            album: nil,
            duration: 180,
            videoId: "video-id"
        )

        let farDuration = LRCLibModel(
            id: 1,
            trackName: "Song",
            artistName: nil,
            albumName: nil,
            duration: 210,
            instrumental: false,
            plainLyrics: "Plain",
            syncedLyrics: nil
        )

        let closeDuration = LRCLibModel(
            id: 2,
            trackName: "Song",
            artistName: nil,
            albumName: nil,
            duration: 181,
            instrumental: false,
            plainLyrics: "Plain",
            syncedLyrics: nil
        )

        let selected = LRCLibProvider.selectBestMatch(from: [farDuration, closeDuration], info: info)

        #expect(selected.id == 2)
    }

    @Test("prefers normalized title match when one candidate uses official video suffix")
    func prefersNormalizedTitleMatch() {
        let info = LyricsSearchInfo(
            title: "Song Name (Official Video)",
            artist: "Artist A",
            album: nil,
            duration: 180,
            videoId: "video-id"
        )

        let wrongTitle = LRCLibModel(
            id: 1,
            trackName: "Different Song",
            artistName: "Artist A",
            albumName: nil,
            duration: 180,
            instrumental: false,
            plainLyrics: "Plain",
            syncedLyrics: nil
        )

        let correctTitle = LRCLibModel(
            id: 2,
            trackName: "Song Name",
            artistName: "Artist A",
            albumName: nil,
            duration: 184,
            instrumental: false,
            plainLyrics: "Plain",
            syncedLyrics: "[00:00.00]Line"
        )

        let selected = LRCLibProvider.selectBestMatch(from: [wrongTitle, correctTitle], info: info)

        #expect(selected.id == 2)
    }
}
