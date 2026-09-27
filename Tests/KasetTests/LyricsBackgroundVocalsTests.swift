import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.service))
struct LyricsBackgroundVocalsTests {
    // MARK: - Parser

    @Test("TTML backing vocals are parsed apart from the lead line")
    func parsesBackingVocalsFromTTML() throws {
        let raw = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <body><div>
            <p begin="0:21.558" end="0:28.555">
              <span begin="0:21.558" end="0:21.891">That's</span> <span begin="0:21.891" end="0:22.153">the</span> <span begin="0:22.153" end="0:23.143">thing</span> <span begin="0:24.167" end="0:26.661">impossible</span> <span begin="0:26.661" end="0:28.555">feelings</span>
              <span ttm:role="x-bg">
                <span begin="0:22.986" end="0:23.380">That's</span> <span begin="0:23.380" end="0:23.548">the</span> <span begin="0:23.548" end="0:23.886">thing</span>
              </span>
            </p>
          </div></body>
        </tt>
        """

        let lyrics = try #require(TTMLParser.parse(raw, source: "Unison"))
        #expect(lyrics.lines.count == 1)

        let line = try #require(lyrics.lines.first)
        // The lead line must never absorb the backing vocal's text — that is the
        // "feelingsThat's" gluing this exists to prevent.
        #expect(line.text == "That's the thing impossible feelings")
        #expect(line.backgroundText == "That's the thing")
        #expect(lyrics.hasBackgroundVocals)
        #expect(lyrics.hasWordTiming)

        let leadWords = try #require(line.words)
        let leadIsAllLead = leadWords.allSatisfy { !$0.isBackground }
        #expect(leadWords.count == 5)
        #expect(leadIsAllLead)

        let backgroundWords = try #require(line.backgroundWords)
        let backingIsAllBacking = backgroundWords.allSatisfy(\.isBackground)
        #expect(backingIsAllBacking)
        // Word boundaries come from the source: only the later backing words carry
        // the separating space, exactly as the lead words do.
        #expect(backgroundWords.map(\.word) == ["That's", " the", " thing"])
        #expect(backgroundWords.map(\.timeInMs) == [22_986, 23_380, 23_548])
    }

    @Test("a line without backing vocals has none")
    func lineWithoutBackgroundVocals() throws {
        let raw = """
        <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
          <p begin="00:00:01.000" end="00:00:02.000">
            <span begin="00:00:01.000" end="00:00:02.000">Hello</span>
          </p>
        </div></body></tt>
        """
        let lyrics = try #require(TTMLParser.parse(raw, source: "Test"))
        #expect(lyrics.lines.first?.backgroundWords == nil)
        #expect(lyrics.lines.first?.backgroundText == nil)
        #expect(lyrics.hasBackgroundVocals == false)
    }

    @Test("translation and romanization spans are still skipped alongside backing vocals")
    func skipsTranslationWithBackingVocals() throws {
        let raw = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>
          <p begin="0:01.000" end="0:03.000">
            <span begin="0:01.000" end="0:01.500">Hello</span> <span begin="0:01.500" end="0:02.000">world</span>
            <span ttm:role="x-translation" begin="0:01.000" end="0:02.000">Bonjour</span>
            <span ttm:role="x-bg"><span begin="0:01.200" end="0:01.400">echo</span></span>
          </p>
        </div></body></tt>
        """
        let lyrics = try #require(TTMLParser.parse(raw, source: "Test"))
        let line = try #require(lyrics.lines.first)
        #expect(line.text == "Hello world")
        #expect(line.backgroundText == "echo")
    }

    // MARK: - Paxsenix structured content

    @Test("Paxsenix content lines flagged as backing go to backgroundWords")
    func paxsenixBackgroundContentLine() throws {
        let content: [PaxsenixLyricsResponse.ContentLine] = [
            PaxsenixLyricsResponse.ContentLine(
                timestamp: 0,
                background: nil,
                oppositeTurn: nil,
                text: [.init(text: "Lead", timestamp: 0, endtime: nil)]
            ),
            PaxsenixLyricsResponse.ContentLine(
                timestamp: 100,
                background: true,
                oppositeTurn: nil,
                text: [.init(text: "Oh", timestamp: 100, endtime: nil)]
            ),
        ]

        let result = PaxsenixProvider.parseContent(content, syllable: true)
        guard case let .synced(lyrics) = result else {
            Issue.record("Expected synced result")
            return
        }

        #expect(lyrics.lines.count == 2)
        #expect(lyrics.lines[0].text == "Lead")
        #expect(lyrics.lines[0].backgroundWords == nil)
        let backingIsAllBacking = lyrics.lines[1].backgroundWords?.allSatisfy(\.isBackground) == true
        #expect(lyrics.lines[1].text == "")
        #expect(lyrics.lines[1].backgroundText == "Oh")
        #expect(backingIsAllBacking)
    }

    // MARK: - Pause detection

    @Test("a line that carries only backing vocals is not a pause")
    func backgroundOnlyLineIsNotPause() {
        let backing = SyncedLyricLine(
            timeInMs: 0,
            duration: 9_000,
            text: "",
            words: nil,
            backgroundWords: [TimedWord(timeInMs: 500, word: "Oh", isBackground: true)]
        )
        let empty = SyncedLyricLine(timeInMs: 10_000, duration: 9_000, text: "", words: nil)

        let lyrics = SyncedLyrics(lines: [backing, empty], source: "Test")
        #expect(lyrics.isPauseLine(at: 0) == false)
        #expect(lyrics.isPauseLine(at: 1))
    }

    // MARK: - Model / cache compatibility

    @Test("backing vocals survive a cache round-trip")
    func backgroundVocalsRoundTrip() throws {
        let line = SyncedLyricLine(
            timeInMs: 0,
            duration: 1_000,
            text: "Lead",
            words: [TimedWord(timeInMs: 0, word: "Lead")],
            backgroundWords: [TimedWord(timeInMs: 100, word: " backing", isBackground: true)]
        )
        let synced = SyncedLyrics(lines: [line], source: "Unison")

        let data = try JSONEncoder().encode(synced)
        let decoded = try JSONDecoder().decode(SyncedLyrics.self, from: data)

        let decodedLine = try #require(decoded.lines.first)
        #expect(decodedLine.text == "Lead")
        #expect(decodedLine.backgroundText == "backing")
        #expect(decodedLine.backgroundWords?.first?.isBackground == true)
        #expect(decodedLine.words?.first?.isBackground == false)
    }

    @Test("lyrics cached before backing vocals existed still decode")
    func decodesLegacyCachedLine() throws {
        // No `backgroundWords` on the line and no `isBackground` on the words.
        let json = #"{"timeInMs":1000,"duration":2000,"text":"Lead","words":[{"timeInMs":1000,"word":"Lead"}]}"#
        let line = try JSONDecoder().decode(SyncedLyricLine.self, from: Data(json.utf8))

        #expect(line.text == "Lead")
        #expect(line.backgroundWords == nil)
        #expect(line.words?.first?.isBackground == false)
    }
}
