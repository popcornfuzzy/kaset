import Testing
@testable import Kaset

@Suite(.tags(.service))
struct PaxsenixProviderTests {
    @Test("Parses ELRC word-timing lines into word-synced lyrics")
    func parsesELRCWithWordTimings() {
        let raw = """
        [00:12.00]{agent:v1}Hello world
        <Hello:12.0:13.2|world:13.4:14.0>
        [00:16.00]{agent:v2}Second line
        """

        let result = PaxsenixProvider.parseELRC(raw)

        #expect(result?.lines.count == 2)
        #expect(result?.hasWordTiming == true)
        #expect(result?.lines[0].text == "Hello world")
        #expect(result?.lines[0].timeInMs == 12000)
        #expect(result?.lines[0].words?.count == 2)
        #expect(result?.lines[0].words?[0].word == "Hello")
        #expect(result?.lines[0].words?[1].word == " world")
        #expect(result?.lines[0].words?[0].timeInMs == 12000)
        #expect(result?.lines[0].words?[1].timeInMs == 13400)
        #expect(result?.lines[1].text == "Second line")
    }

    @Test("Parses plain LRC into line-synced lyrics")
    func parsesPlainLRC() {
        let raw = "[00:12.00]First line\n[00:16.00]Second line"
        let result = PaxsenixProvider.parseELRC(raw)
        #expect(result?.lines.count == 2)
        #expect(result?.hasWordTiming == false)
        #expect(result?.lines[0].duration == 4000)
    }

    @Test("Parses Apple Music TTML with word spans")
    func parsesTTMLWithSpans() {
        let raw = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml">
          <body><div>
            <p begin="00:00:01.500" end="00:00:04.000">
              <span begin="00:00:01.500" end="00:00:02.100">Hello</span>
              <span begin="00:00:02.200" end="00:00:03.000"> world</span>
            </p>
          </div></body>
        </tt>
        """

        let result = PaxsenixProvider.parseTTML(raw)

        #expect(result?.lines.count == 1)
        #expect(result?.hasWordTiming == true)
        #expect(result?.lines[0].text == "Hello world")
        #expect(result?.lines[0].timeInMs == 1500)
        #expect(result?.lines[0].words?.count == 2)
        #expect(result?.lines[0].words?[0].timeInMs == 1500)
        #expect(result?.lines[0].words?[1].word == " world")
    }

    @Test("Parses TTML without span timings as line-synced")
    func parsesTTMLWithoutSpans() {
        let raw = """
        <tt><body><div>
          <p begin="00:00:10.00" end="00:00:15.00">Just a line</p>
        </div></body></tt>
        """
        let result = PaxsenixProvider.parseTTML(raw)
        #expect(result?.lines.count == 1)
        #expect(result?.hasWordTiming == false)
        #expect(result?.lines[0].text == "Just a line")
        #expect(result?.lines[0].timeInMs == 10000)
    }

    @Test("Converts syllable content arrays to word-synced lyrics")
    func parsesSyllableContent() {
        let content = [
            PaxsenixLyricsResponse.ContentLine(
                timestamp: 1000,
                background: nil,
                oppositeTurn: nil,
                text: [
                    PaxsenixLyricsResponse.ContentWord(text: "Hey", timestamp: 1000, endtime: 1300),
                    PaxsenixLyricsResponse.ContentWord(text: "there", timestamp: 1400, endtime: 1800),
                ]
            ),
        ]
        let result = PaxsenixProvider.parseContent(content, syllable: true)
        guard case let .synced(lyrics) = result else {
            Issue.record("Expected synced result")
            return
        }
        #expect(lyrics.hasWordTiming)
        #expect(lyrics.lines[0].text == "Hey there")
        #expect(lyrics.lines[0].words?.count == 2)
        #expect(lyrics.lines[0].words?[1].word == " there")
    }

    @Test("Converts non-syllable content arrays to plain lyrics")
    func parsesPlainContent() {
        let content = [
            PaxsenixLyricsResponse.ContentLine(timestamp: 1000, background: nil, oppositeTurn: nil, text: [.init(text: "First", timestamp: nil, endtime: nil)]),
            PaxsenixLyricsResponse.ContentLine(timestamp: 2000, background: nil, oppositeTurn: nil, text: [.init(text: "Second", timestamp: nil, endtime: nil)]),
        ]
        let result = PaxsenixProvider.parseContent(content, syllable: false)
        guard case let .plain(lyrics) = result else {
            Issue.record("Expected plain result")
            return
        }
        #expect(lyrics.text == "First\nSecond")
    }

    @Test("Response parsing prefers word-synced over plain lyrics")
    func responsePrefersWordSynced() {
        let response = PaxsenixLyricsResponse(
            type: "Syllable",
            ttmlContent: nil,
            elrcMultiPerson: nil,
            elrc: "[00:10.00]Line\n<Line:10.0:11.0>",
            plain: "Fallback plain text",
            content: nil
        )
        let result = PaxsenixProvider.parse(response)
        guard case let .synced(lyrics) = result else {
            Issue.record("Expected synced result")
            return
        }
        #expect(lyrics.hasWordTiming)
        #expect(lyrics.source == "Paxsenix")
    }

    @Test("cleanTitle strips version markers")
    func cleanTitleStripsMarkers() {
        #expect(PaxsenixProvider.cleanTitle("Blinding Lights (Official Video)") == "Blinding Lights")
        #expect(PaxsenixProvider.cleanTitle("Song Name [Live]") == "Song Name")
        #expect(PaxsenixProvider.cleanTitle("Title - Official Audio") == "Title")
        #expect(PaxsenixProvider.cleanTitle("Track (feat. Someone)") == "Track")
    }

    @Test("cleanArtist keeps only the primary artist")
    func cleanArtistKeepsPrimary() {
        #expect(PaxsenixProvider.cleanArtist("The Weeknd, Ariana Grande") == "The Weeknd")
        #expect(PaxsenixProvider.cleanArtist("Daft Punk feat. Pharrell Williams") == "Daft Punk")
        #expect(PaxsenixProvider.cleanArtist("Muse") == "Muse")
    }

    @Test("scoreAndFilter prefers exact title and close duration")
    func scoresAndFiltersResults() {
        let tracks = [
            PaxsenixTrack(id: "1", name: "Blinding Lights (Live)", artist: "The Weeknd", duration: 230),
            PaxsenixTrack(id: "2", name: "Blinding Lights", artist: "The Weeknd", duration: 200),
            PaxsenixTrack(id: "3", name: "NOKIA", artist: "Drake", duration: 190),
        ]
        let scored = PaxsenixProvider.scoreAndFilter(tracks, title: "Blinding Lights", artist: "The Weeknd", duration: 202)
        #expect(scored.first?.id == "2")
        #expect(scored.contains { $0.id == "3" } == false)
    }
}