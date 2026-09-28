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

    // MARK: - Pause dots in word-synced lyrics

    @Test("word-synced TTML keeps instrumental-gap paragraphs as pause lines")
    func ttmlKeepsInstrumentalGap() throws {
        let raw = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <body><div>
            <p begin="0:01.000" end="0:02.000">
              <span begin="0:01.000" end="0:02.000">Hello</span>
            </p>
            <p begin="0:02.000" end="0:05.000" />
            <p begin="0:05.000" end="0:06.000">
              <span begin="0:05.000" end="0:06.000">World</span>
            </p>
          </div></body>
        </tt>
        """

        let lyrics = try #require(TTMLParser.parse(raw, source: "Test"))
        #expect(lyrics.lines.count == 3)
        #expect(lyrics.lines[1].text.isEmpty)
        #expect(lyrics.lines[1].timeInMs == 2_000)
        #expect(lyrics.lines[1].duration == 3_000)
        // The gap line is a pause interlude, so the renderer shows the dots there.
        #expect(lyrics.isPauseLine(at: 1))
    }

    @Test("a TTML paragraph with no timing at all is still dropped")
    func ttmlDropsUntimedEmptyParagraph() throws {
        let raw = """
        <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
          <p begin="0:01.000" end="0:02.000"><span begin="0:01.000" end="0:02.000">Hello</span></p>
          <p></p>
        </div></body></tt>
        """

        let lyrics = try #require(TTMLParser.parse(raw, source: "Test"))
        #expect(lyrics.lines.count == 1)
    }

    @Test("Paxsenix syllable content keeps empty timed entries as pause lines")
    func paxsenixKeepsEmptyTimedEntry() {
        let content: [PaxsenixLyricsResponse.ContentLine] = [
            PaxsenixLyricsResponse.ContentLine(
                timestamp: 1_000,
                background: nil,
                oppositeTurn: nil,
                text: [.init(text: "Hello", timestamp: 1_000, endtime: nil)]
            ),
            PaxsenixLyricsResponse.ContentLine(
                timestamp: 2_000,
                background: nil,
                oppositeTurn: nil,
                text: []
            ),
            PaxsenixLyricsResponse.ContentLine(
                timestamp: 5_000,
                background: nil,
                oppositeTurn: nil,
                text: [.init(text: "World", timestamp: 5_000, endtime: nil)]
            ),
        ]

        guard case let .synced(lyrics) = PaxsenixProvider.parseContent(content, syllable: true) else {
            Issue.record("Expected synced result")
            return
        }

        #expect(lyrics.lines.count == 3)
        #expect(lyrics.lines[1].text.isEmpty)
        #expect(lyrics.lines[1].duration == 3_000)
        #expect(lyrics.isPauseLine(at: 1))
    }

    @Test("Paxsenix ELRC keeps empty timed lines as pause lines")
    func elrcKeepsEmptyTimedLine() throws {
        let raw = """
        [00:01.000]{v1}Hello
        [00:02.000]
        [00:05.000]{v1}World
        """

        let lyrics = try #require(PaxsenixProvider.parseELRC(raw))
        #expect(lyrics.lines.count == 3)
        #expect(lyrics.lines[1].text.isEmpty)
        #expect(lyrics.lines[1].timeInMs == 2_000)
        #expect(lyrics.isPauseLine(at: 1))
    }

    // MARK: - Karaoke animation

    /// A lead line with one backing vocal that starts later and ends later, the shape the
    /// Autobahn TTML and Apple Music's own x-bg markup produce.
    private func lineWithBackingVocal() -> SyncedLyricLine {
        SyncedLyricLine(
            timeInMs: 1_000,
            duration: 4_000,
            text: "Stare at the sun",
            words: [
                TimedWord(timeInMs: 1_000, word: "Stare"),
                TimedWord(timeInMs: 1_400, word: " at"),
                TimedWord(timeInMs: 1_800, word: " the"),
                TimedWord(timeInMs: 2_200, word: " sun"),
            ],
            backgroundWords: [
                TimedWord(timeInMs: 1_500, word: "Ooh", isBackground: true),
                TimedWord(timeInMs: 3_000, word: " oh", isBackground: true),
            ]
        )
    }

    @Test("backing vocal words carry their own fill windows, not the lead's")
    func backgroundWordsFillOnTheirOwnTiming() throws {
        let line = self.lineWithBackingVocal()
        let background = KaraokeFillModel.backgroundWords(for: line)

        #expect(background.count == 2)
        #expect(background.map(\.text) == ["Ooh", "oh"])
        // The first backing word is timed from its own onset (1 500 ms, less the attack
        // lead), never interpolated from the lead's first word.
        #expect(abs(background[0].fillStartMs - 1_430) < 1)
        // The last backing word fills from its own onset, and — like a lead word — is
        // clamped to a 1 200 ms ramp, so a held note lands instead of crawling: 3 000 +
        // 1 200, less the release tail. It still ends well past the lead's last word.
        #expect(abs(background[1].fillEndMs - 4_160) < 1)
    }

    @Test("the backing synthetic line keeps the line's identity and timing")
    func backingVocalLineKeepsIdentity() throws {
        let line = self.lineWithBackingVocal()
        let backing = line.backingVocalLine

        #expect(backing.id == line.id)
        #expect(backing.timeInMs == line.timeInMs)
        #expect(backing.duration == line.duration)
        #expect(backing.text.isEmpty)
        #expect(backing.words?.map(\.word) == line.backgroundWords?.map(\.word))
        #expect(backing.backgroundWords == nil)
    }

    @Test("the row stays on the display clock until the backing vocal lands")
    func settleBoundaryCoversBackingVocal() throws {
        let line = self.lineWithBackingVocal()

        // The lead's last ramp ends at 3 360 ms, the backing's at 4 160 ms, and the line's
        // declared end is 5 000 ms: the boundary is the latest of the three, so the row stays
        // on the clock until the backing vocal has landed too.
        let boundary = KaraokeFillModel.settleBoundaryMs(for: line)
        #expect(abs(boundary - 5_000) < 1)
        #expect(boundary > KaraokeFillModel.words(for: line).map(\.fillEndMs).max().unwrapOrFallback())
        #expect(boundary > KaraokeFillModel.backgroundWords(for: line).map(\.fillEndMs).max().unwrapOrFallback())
    }

    @Test("a line without backing vocals settles exactly as before")
    func settleBoundaryUnchangedWithoutBackingVocals() {
        let line = SyncedLyricLine(
            timeInMs: 1_000,
            duration: 4_000,
            text: "Plain",
            words: [TimedWord(timeInMs: 1_000, word: "Plain")]
        )

        let boundary = KaraokeFillModel.settleBoundaryMs(for: line)
        let declaredEnd = 5_000.0
        #expect(abs(boundary - declaredEnd) < 1)
    }

    @Test("backing vocals fill synchronously with the lead on a shared clock")
    func backingAndLeadFillOnSharedClock() throws {
        let line = self.lineWithBackingVocal()
        let lead = KaraokeFillModel.words(for: line)
        let background = KaraokeFillModel.backgroundWords(for: line)

        // At a position between the lead's last word and the backing's last word, the lead
        // is fully sung while the backing is still filling: both are rendered from the same
        // playback position, and each from its own windows.
        let sharedClock: Double = 4_000
        #expect(lead.allSatisfy { $0.fill(at: sharedClock) == 1 })
        #expect(background[0].fill(at: sharedClock) == 1)
        #expect(background[1].fill(at: sharedClock) > 0)
        #expect(background[1].fill(at: sharedClock) < 1)
    }
}

private extension Optional where Wrapped == Double {
    /// Reads cleanly in a comparison where the fallback value is fine to substitute.
    func unwrapOrFallback() -> Double {
        self ?? 0
    }
}
