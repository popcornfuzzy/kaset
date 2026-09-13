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
