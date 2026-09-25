import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.service))
struct KuGoProviderTests {
    // MARK: - Keyword generation

    @Test("generateKeyword normalizes title, artist, and album")
    func generatesKeyword() {
        let keyword = KuGoProvider.generateKeyword(
            title: "Blinding Lights (Official Video)",
            artist: "The Weeknd & Daft Punk",
            album: "After Hours"
        )
        #expect(keyword.title == "Blinding Lights")
        #expect(keyword.artist == "The Weeknd、Daft Punk")
        #expect(keyword.album == "After Hours")
    }

    @Test("normalizeTitle strips bracketed annotations in all styles")
    func normalizesTitle() {
        #expect(KuGoProvider.normalizeTitle("Song (Live)") == "Song")
        #expect(KuGoProvider.normalizeTitle("歌（现场版）") == "歌")
        #expect(KuGoProvider.normalizeTitle("Song「アニメ盤」") == "Song")
        #expect(KuGoProvider.normalizeTitle("Song『Special』") == "Song")
        #expect(KuGoProvider.normalizeTitle("Song《专辑》") == "Song")
        #expect(KuGoProvider.normalizeTitle("Song <Live>") == "Song")
        #expect(KuGoProvider.normalizeTitle("Plain Title") == "Plain Title")
    }

    @Test("normalizeArtist merges multiple artists and strips annotations")
    func normalizesArtist() {
        #expect(KuGoProvider.normalizeArtist("A & B") == "A、B")
        #expect(KuGoProvider.normalizeArtist("A, B") == "A、B")
        #expect(KuGoProvider.normalizeArtist("A和B") == "A、B")
        #expect(KuGoProvider.normalizeArtist("A.B") == "AB")
        #expect(KuGoProvider.normalizeArtist("Artist (Remix)") == "Artist")
        #expect(KuGoProvider.normalizeArtist("Solo Artist") == "Solo Artist")
    }

    // MARK: - LRC normalization

    @Test("normalize keeps timestamped lines and strips head metadata")
    func normalizesLRC() {
        let raw = """
        [ti:Blinding Lights]
        [ar:The Weeknd]
        [00:12.34]Hello world
        [00:16.50]Second line
        """
        #expect(KuGoProvider.normalize(raw) == "[00:12.34]Hello world\n[00:16.50]Second line")
    }

    @Test("normalize strips trailing metadata lines")
    func stripsTrailingMetadata() {
        let raw = """
        [00:12.34]Hello world
        [00:16.50]Second line
        [by:kuge]
        """
        #expect(KuGoProvider.normalize(raw) == "[00:12.34]Hello world\n[00:16.50]Second line")
    }

    @Test("normalize trims everything up to a colon annotation line")
    func stripsColonAnnotationLines() {
        // The reference implementation cuts the head up to the last banned line
        // inside the first 30 lines, so a mid-lyrics annotation line also
        // removes the earlier lines. Ported faithfully.
        let raw = """
        [00:12.34]Hello world
        [00:14.00]作词：林夕
        [00:16.50]Second line
        """
        #expect(KuGoProvider.normalize(raw) == "[00:16.50]Second line")
    }

    @Test("normalize drops non-LRC lines entirely")
    func dropsNonLRCLines() {
        let raw = "Not a timestamped line\n[00:12.34]Hello world"
        #expect(KuGoProvider.normalize(raw) == "[00:12.34]Hello world")
    }

    @Test("normalize returns empty when no timestamped lines exist")
    func emptyWhenNoTimestamps() {
        #expect(KuGoProvider.normalize("just some text") == "")
        #expect(KuGoProvider.normalize("") == "")
    }

    // MARK: - Base64 pipeline

    @Test("processContent decodes base64 LRC into synced lyrics")
    func processesBase64LRC() {
        let lrc = "[00:12.34]Hello world\n[00:16.50]Second line"
        let base64 = Data(lrc.utf8).base64EncodedString()
        let result = KuGoProvider.processContent(base64)
        guard case let .synced(lyrics) = result else {
            Issue.record("Expected synced result")
            return
        }
        #expect(lyrics.source == "KuGo")
        #expect(lyrics.hasWordTiming == false)
        // LRCParser inserts an empty 0ms line when the first timestamp is late.
        #expect(lyrics.lines.count == 3)
        #expect(lyrics.lines[0].text == "")
        #expect(lyrics.lines[1].text == "Hello world")
        #expect(lyrics.lines[1].timeInMs == 12340)
        #expect(lyrics.lines[2].timeInMs == 16500)
    }

    @Test("processContent handles base64 with embedded newlines")
    func processesBase64WithNewlines() {
        let lrc = "[00:01.00]Line"
        let raw = Data(lrc.utf8).base64EncodedString()
        let wrapped = String(raw.enumerated().map { $0.offset % 40 == 39 ? "\n" : $0.element })
        let result = KuGoProvider.processContent(wrapped)
        #expect(result.isAvailable)
    }

    @Test("processContent returns unavailable for invalid base64 or garbage")
    func unavailableForInvalidContent() {
        #expect(KuGoProvider.processContent("not-base64!!") == .unavailable)
        #expect(KuGoProvider.processContent("") == .unavailable)
        // Valid base64 but not LRC text.
        let garbage = Data("hello".utf8).base64EncodedString()
        #expect(KuGoProvider.processContent(garbage) == .unavailable)
    }

    // MARK: - Candidate decoding

    @Test("candidate decoding accepts an id sent as a JSON string")
    func decodesStringCandidateID() throws {
        // The lyrics search endpoint started quoting the id: decoding it as an
        // Int64-only field failed the whole response, so KuGo reported "no
        // lyrics" for every song.
        let json = #"[{"id":"209655425","accesskey":"test-access-key"}]"#
        let candidates = try JSONDecoder().decode([KuGoLyricsCandidate].self, from: Data(json.utf8))
        #expect(candidates.count == 1)
        #expect(candidates.first?.id == 209_655_425)
        #expect(candidates.first?.accesskey == "test-access-key")
    }

    @Test("candidate decoding accepts an id sent as a JSON number")
    func decodesNumericCandidateID() throws {
        let json = #"[{"id":209655425,"accesskey":"test-access-key"}]"#
        let candidates = try JSONDecoder().decode([KuGoLyricsCandidate].self, from: Data(json.utf8))
        #expect(candidates.first?.id == 209_655_425)
    }

    @Test("candidate decoding tolerates a missing or unusable id")
    func decodesCandidateWithoutID() throws {
        let json = #"[{"accesskey":"test-access-key"},{"id":"not-a-number"}]"#
        let candidates = try JSONDecoder().decode([KuGoLyricsCandidate].self, from: Data(json.utf8))
        #expect(candidates.count == 2)
        #expect(candidates[0].id == nil)
        #expect(candidates[0].accesskey == "test-access-key")
        #expect(candidates[1].id == nil)
    }

    // MARK: - Candidate matching

    @Test("isSongAcceptable applies the duration tolerance")
    func durationTolerance() {
        #expect(KuGoProvider.isSongAcceptable(KuGoSongInfo(hash: "h", duration: 200), duration: 200))
        #expect(KuGoProvider.isSongAcceptable(KuGoSongInfo(hash: "h", duration: 205), duration: 200))
        #expect(KuGoProvider.isSongAcceptable(KuGoSongInfo(hash: "h", duration: 192), duration: 200))
        #expect(KuGoProvider.isSongAcceptable(KuGoSongInfo(hash: "h", duration: 210), duration: 200) == false)
        #expect(KuGoProvider.isSongAcceptable(KuGoSongInfo(hash: "h", duration: 190), duration: 200) == false)
        // A song without a known duration can't be verified against a known
        // target, so it is rejected.
        #expect(KuGoProvider.isSongAcceptable(KuGoSongInfo(hash: "h", duration: nil), duration: 200) == false)
        // An unknown target duration accepts any song.
        #expect(KuGoProvider.isSongAcceptable(KuGoSongInfo(hash: "h", duration: 200), duration: nil))
        #expect(KuGoProvider.isSongAcceptable(KuGoSongInfo(hash: "h", duration: nil), duration: nil))
    }
}