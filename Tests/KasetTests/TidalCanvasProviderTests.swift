import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.service))
struct TidalCanvasProviderTests {
    // MARK: - Video URL formatting

    @Test("formatVideoUrl builds a playable MP4 URL from a 5-part videoCover id")
    func formatVideoUrl() {
        let url = TidalCanvasProvider.formatVideoUrl("abc-123-456-789-def")
        #expect(url?.absoluteString == "https://resources.tidal.com/videos/abc/123/456/789/def/1280x1280.mp4")
    }

    @Test("formatVideoUrl rejects ids without exactly five parts")
    func formatVideoUrlRejectsInvalid() {
        #expect(TidalCanvasProvider.formatVideoUrl("abc-123") == nil)
        #expect(TidalCanvasProvider.formatVideoUrl("") == nil)
        #expect(TidalCanvasProvider.formatVideoUrl("a-b-c-d-e-f") == nil)
    }

    // MARK: - Matching helpers

    @Test("normalizeForComparison lowercases, trims, collapses whitespace, strips punctuation")
    func normalizeForComparison() {
        #expect(CanvasMatching.normalizeForComparison("  Blinding   Lights!  ") == "blinding lights")
        #expect(CanvasMatching.normalizeForComparison("After Hours") == "after hours")
        #expect(CanvasMatching.normalizeForComparison("") == "")
    }

    @Test("artistComponents splits on separators and normalizes each component")
    func artistComponents() {
        #expect(CanvasMatching.artistComponents("Drake, 21 Savage") == ["drake", "21 savage"])
        #expect(CanvasMatching.artistComponents("A & B") == ["a", "b"])
        #expect(CanvasMatching.artistComponents("A x B") == ["a", "b"])
        #expect(CanvasMatching.artistComponents("A × B") == ["a", "b"])
        #expect(CanvasMatching.artistComponents("A feat. B") == ["a", "b"])
        #expect(CanvasMatching.artistComponents("A ft B") == ["a", "b"])
        #expect(CanvasMatching.artistComponents("A featuring B") == ["a", "b"])
        #expect(CanvasMatching.artistComponents("A with B") == ["a", "b"])
        #expect(CanvasMatching.artistComponents("Solo Artist") == ["solo artist"])
    }

    @Test("normalizeForComparison folds diacritics so accented names still match")
    func normalizeForComparisonFoldsDiacritics() {
        #expect(CanvasMatching.normalizeForComparison("ROSALÍA") == CanvasMatching.normalizeForComparison("Rosalia"))
        #expect(CanvasMatching.normalizeForComparison("Beyoncé") == CanvasMatching.normalizeForComparison("Beyonce"))
        #expect(CanvasMatching.normalizeForComparison("Motörhead") == CanvasMatching.normalizeForComparison("Motorhead"))
        #expect(CanvasMatching.normalizeForComparison("Björk") == "bjork")
        // The combining mark itself must not survive as a character.
        #expect(CanvasMatching.normalizeForComparison("Café") == "cafe")
    }

    @Test("normalizeForComparison treats punctuation as a separator, not a deletion")
    func normalizeForComparisonSeparatesPunctuation() {
        // Regression: deleting the hyphen made "Anti-Hero" normalize to
        // "antihero", which never equals "Anti Hero"'s "anti hero".
        #expect(CanvasMatching.normalizeForComparison("Anti-Hero") == CanvasMatching.normalizeForComparison("Anti Hero"))
        #expect(CanvasMatching.normalizeForComparison("Anti-Hero") == "anti hero")
        #expect(CanvasMatching.normalizeForComparison("Mr. Brightside") == "mr brightside")
    }

    @Test("normalizeForComparison keeps non-Latin letters instead of collapsing them away")
    func normalizeForComparisonKeepsNonLatin() {
        // The Android reference restricted to [a-z0-9], which would reduce every
        // Cyrillic/CJK title to the empty string and make it match nothing.
        #expect(CanvasMatching.normalizeForComparison("сигнал") == "сигнал")
        #expect(CanvasMatching.normalizeForComparison("夜に駆ける") == "夜に駆ける")
        #expect(!CanvasMatching.normalizeForComparison("сигнал").isEmpty)
    }

    // MARK: - Search plan

    @Test("searchAttempts orders song-first and leads with the song + artist track query")
    func searchAttemptsOrdering() {
        let attempts = TidalCanvasProvider.searchAttempts(for: CanvasSearchInfo(
            title: "Blinding Lights",
            artist: "The Weeknd",
            album: "After Hours",
            videoId: "x"
        ))

        #expect(attempts.map(\.query) == [
            "The Weeknd Blinding Lights",
            "After Hours The Weeknd",
            "The Weeknd Blinding Lights",
            "After Hours The Weeknd Blinding Lights",
        ])
        #expect(attempts.map(\.types) == ["TRACKS", "ALBUMS", "ALBUMS", "TRACKS"])

        let first = attempts[0]
        #expect(first.songValidation == "Blinding Lights")
        #expect(first.artistValidation == "The Weeknd")
        #expect(first.albumValidation == nil)

        // The single lookup validates the album entry against the song title.
        let single = attempts[2]
        #expect(single.albumValidation == "Blinding Lights")
    }

    /// Regression: the song + artist track query must never carry the album.
    /// Including it makes Tidal rank the song's *album release* first, and that
    /// entry frequently has no video cover even when the single does ("Flowers"
    /// vs "Endless Summer Vacation").
    @Test("the leading track query excludes the album")
    func leadingTrackQueryExcludesAlbum() {
        let attempts = TidalCanvasProvider.searchAttempts(for: CanvasSearchInfo(
            title: "Flowers",
            artist: "Miley Cyrus",
            album: "Endless Summer Vacation",
            videoId: "x"
        ))
        #expect(attempts.first?.query == "Miley Cyrus Flowers")
        #expect(attempts.first?.types == "TRACKS")
        #expect(attempts.first?.query.contains("Endless Summer Vacation") == false)
    }

    @Test("searchAttempts skips album attempts when the album is unknown")
    func searchAttemptsWithoutAlbum() {
        let attempts = TidalCanvasProvider.searchAttempts(for: CanvasSearchInfo(
            title: "Flowers",
            artist: "Miley Cyrus",
            album: nil,
            videoId: "x"
        ))
        #expect(attempts.count == 2)
        #expect(attempts.map(\.types) == ["TRACKS", "ALBUMS"])
        #expect(attempts.allSatisfy { $0.query == "Miley Cyrus Flowers" })
        #expect(attempts[1].albumValidation == "Flowers")
    }

    @Test("searchAttempts skips song attempts when the title is blank")
    func searchAttemptsWithoutSong() {
        let attempts = TidalCanvasProvider.searchAttempts(for: CanvasSearchInfo(
            title: "   ",
            artist: "The Weeknd",
            album: "After Hours",
            videoId: "x"
        ))
        #expect(attempts.count == 1)
        #expect(attempts[0].query == "After Hours The Weeknd")
        #expect(attempts[0].types == "ALBUMS")
    }

    // MARK: - Candidate extraction

    @Test("extractCandidate validates song title strictly and reads the album videoCover")
    func extractCandidateSongValidation() {
        let track: [String: Any] = [
            "title": "Blinding Lights",
            "artists": [["name": "The Weeknd"]],
            "album": ["title": "After Hours", "videoCover": "111-222-333-444-555"],
        ]
        let candidate = TidalCanvasProvider.extractCandidate(
            from: track,
            songValidation: "blinding lights",
            artistValidation: "The Weeknd",
            albumValidation: nil
        )
        #expect(candidate?.videoCover == "111-222-333-444-555")
        #expect(candidate?.title == "Blinding Lights")
        #expect(candidate?.artist == "The Weeknd")
        #expect(candidate?.album == "After Hours")

        let wrongSong = TidalCanvasProvider.extractCandidate(
            from: track,
            songValidation: "Wrong Song",
            artistValidation: "The Weeknd",
            albumValidation: nil
        )
        #expect(wrongSong == nil)
    }

    @Test("extractCandidate requires every requested artist to be present")
    func extractCandidateArtistValidation() {
        let track: [String: Any] = [
            "title": "God's Plan",
            "artists": [["name": "Drake"], ["name": "21 Savage"]],
            "album": ["title": "Scorpion", "videoCover": "a-b-c-d-e"],
        ]
        // The full artist list matches.
        let full = TidalCanvasProvider.extractCandidate(
            from: track,
            songValidation: nil,
            artistValidation: "Drake, 21 Savage",
            albumValidation: nil
        )
        #expect(full != nil)

        // A subset matches: every requested artist is present.
        let subset = TidalCanvasProvider.extractCandidate(
            from: track,
            songValidation: nil,
            artistValidation: "Drake",
            albumValidation: nil
        )
        #expect(subset != nil)

        // A missing artist is rejected.
        let missing = TidalCanvasProvider.extractCandidate(
            from: track,
            songValidation: nil,
            artistValidation: "Kendrick Lamar",
            albumValidation: nil
        )
        #expect(missing == nil)
    }

    @Test("extractCandidate validates album title and reads a top-level videoCover for albums")
    func extractCandidateAlbumValidation() {
        let album: [String: Any] = [
            "title": "After Hours",
            "artists": [["name": "The Weeknd"]],
            "videoCover": "a-b-c-d-e",
        ]
        let ok = TidalCanvasProvider.extractCandidate(
            from: album,
            songValidation: nil,
            artistValidation: "The Weeknd",
            albumValidation: "after hours"
        )
        #expect(ok != nil)
        #expect(ok?.videoCover == "a-b-c-d-e")
        #expect(ok?.album == "After Hours")

        let wrongAlbum = TidalCanvasProvider.extractCandidate(
            from: album,
            songValidation: nil,
            artistValidation: "The Weeknd",
            albumValidation: "Dawn FM"
        )
        #expect(wrongAlbum == nil)
    }

    // MARK: - Album affiliation

    @Test("albumItemsContainTrack reads the wrapped item shape and matches normalized titles")
    func albumItemsContainTrackWrappedShape() {
        let response: [String: Any] = [
            "totalNumberOfItems": 2,
            "items": [
                ["item": ["id": 1, "title": "SOS"]],
                ["item": ["id": 2, "title": "Good Days"]],
            ],
        ]
        #expect(TidalCanvasProvider.albumItemsContainTrack(response, title: "Good Days"))
        // Normalization applies, so decoration and case do not defeat the check.
        #expect(TidalCanvasProvider.albumItemsContainTrack(response, title: "good days"))
        #expect(TidalCanvasProvider.albumItemsContainTrack(response, title: "Good-Days"))
        #expect(TidalCanvasProvider.albumItemsContainTrack(response, title: "Kill Bill") == false)
    }

    @Test("albumItemsContainTrack accepts a bare track shape and rejects malformed input")
    func albumItemsContainTrackBareShape() {
        let bare: [String: Any] = ["items": [["title": "Blinding Lights"]]]
        #expect(TidalCanvasProvider.albumItemsContainTrack(bare, title: "Blinding Lights"))

        #expect(TidalCanvasProvider.albumItemsContainTrack([:], title: "Anything") == false)
        #expect(TidalCanvasProvider.albumItemsContainTrack(["items": [[:]]], title: "Anything") == false)
        // An empty needle must never match, or affiliation would accept any album.
        #expect(TidalCanvasProvider.albumItemsContainTrack(bare, title: "   ") == false)
    }

    @Test("albumId reads Tidal's numeric album ids as well as string ids")
    func albumIdParsing() {
        #expect(TidalCanvasProvider.albumId(from: ["id": NSNumber(value: 264617506)]) == "264617506")
        #expect(TidalCanvasProvider.albumId(from: ["id": "abc"]) == "abc")
        #expect(TidalCanvasProvider.albumId(from: [:]) == nil)
    }

    @Test("artistNames prefers the artists array and falls back to the single artist object")
    func artistNamesParsing() {
        #expect(TidalCanvasProvider.artistNames(from: ["artists": [["name": "Drake"], ["name": "21 Savage"]]]) == ["Drake", "21 Savage"])
        #expect(TidalCanvasProvider.artistNames(from: ["artist": ["name": "SZA"]]) == ["SZA"])
        #expect(TidalCanvasProvider.artistNames(from: [:]).isEmpty)
    }

    @Test("artistMatches requires every requested artist and passes when unconstrained")
    func artistMatchesValidation() {
        #expect(TidalCanvasProvider.artistMatches(validation: "SZA", returned: ["SZA"]))
        #expect(TidalCanvasProvider.artistMatches(validation: "Drake", returned: ["Drake", "21 Savage"]))
        #expect(TidalCanvasProvider.artistMatches(validation: "Drake, 21 Savage", returned: ["Drake"]) == false)
        #expect(TidalCanvasProvider.artistMatches(validation: "Kendrick Lamar", returned: ["Drake"]) == false)
        #expect(TidalCanvasProvider.artistMatches(validation: "Kendrick Lamar", returned: []) == false)
        // No constraint asked for.
        #expect(TidalCanvasProvider.artistMatches(validation: nil, returned: ["Drake"]))
        #expect(TidalCanvasProvider.artistMatches(validation: "  ", returned: []))
    }

    // MARK: - Response section finding

    @Test("findSearchSection locates the items container under the requested key")
    func findSearchSection() {
        let data: [String: Any] = [
            "albums": ["items": [["title": "After Hours"]]],
        ]
        let section = TidalCanvasProvider.findSearchSection(in: data, key: "albums")
        #expect(section != nil)
        #expect((section?["items"] as? [[String: Any]])?.count == 1)
        // A response with no items anywhere yields nil for any key.
        #expect(TidalCanvasProvider.findSearchSection(in: ["empty": [:]], key: "albums") == nil)
    }

    @Test("a full album response resolves to a canvas artwork via pure parsing")
    func fullResponseResolvesToCanvas() {
        let response: [String: Any] = [
            "albums": ["items": [[
                "title": "After Hours",
                "artists": [["name": "The Weeknd"]],
                "videoCover": "a1-b2-c3-d4-e5",
            ]]],
        ]
        guard let section = TidalCanvasProvider.findSearchSection(in: response, key: "albums"),
              let items = section["items"] as? [[String: Any]],
              let item = items.first,
              let candidate = TidalCanvasProvider.extractCandidate(
                  from: item,
                  songValidation: nil,
                  artistValidation: "The Weeknd",
                  albumValidation: "After Hours"
              ),
              let videoCover = candidate.videoCover,
              let url = TidalCanvasProvider.formatVideoUrl(videoCover)
        else {
            Issue.record("Expected a resolvable canvas")
            return
        }
        #expect(url.absoluteString == "https://resources.tidal.com/videos/a1/b2/c3/d4/e5/1280x1280.mp4")
        #expect(candidate.artist == "The Weeknd")
        #expect(candidate.album == "After Hours")
    }
}
