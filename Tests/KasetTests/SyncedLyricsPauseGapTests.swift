import Foundation
import Testing
@testable import Kaset

/// The pause dots need a *line* to render on, and word-synced sources never give one.
///
/// Every word-synced provider Kaset uses (Unison, BetterLyrics, Paxsenix's TTML) writes
/// Apple Music's TTML, and its paragraphs are contiguous *within* a line but skip whole
/// bars *between* them: there is no empty paragraph anywhere in the document. So the dots
/// appeared in line-synced lyrics, where the LRC format does spell an interlude out as a
/// timestamped line with no text, and never in word-by-word lyrics — the mode they were
/// asked for.
///
/// The gap between two paragraphs is the interlude. These pin that it becomes a row, that
/// it is exactly one row per gap and it covers exactly the gap, that a source which spells
/// its interludes out anyway does not get two rows for one silence, and that the rows leave
/// the sheet's indices — the ones the highlight, the scroll target and the row statuses all
/// read — consistent.
@Suite(.tags(.model))
struct SyncedLyricsPauseGapTests {
    // MARK: - Synthesis

    @Test("An interlude left as a gap between two lines becomes a pause row")
    func gapBecomesPauseRow() {
        let lyrics = self.sheet([(0, 1_000, "First"), (2_800, 1_000, "Second")])

        let filled = lyrics.withPauseInterludes()

        #expect(filled.lines.count == 3)
        let pause = filled.lines[1]
        #expect(SyncedLyrics.isSilent(pause))
        #expect(pause.timeInMs == 1_000)
        #expect(pause.duration == 1_800)
        #expect(filled.isPauseLine(at: 1))
    }

    @Test("A gap too short to hold the dots is left alone")
    func shortGapIsLeftAlone() {
        let lyrics = self.sheet([(0, 1_000, "First"), (1_400, 1_000, "Second")])

        #expect(lyrics.withPauseInterludes().lines.count == 2)
    }

    @Test("A source that spells its interlude out does not get a second row for it")
    func explicitPauseLineIsNotDoubled() {
        let lines = [
            SyncedLyricLine(timeInMs: 0, duration: 1_000, text: "First", words: nil),
            SyncedLyricLine(timeInMs: 1_000, duration: 1_800, text: "", words: nil),
            SyncedLyricLine(timeInMs: 2_800, duration: 1_000, text: "Second", words: nil),
        ]

        let filled = SyncedLyrics(lines: lines, source: "UnitTest").withPauseInterludes()

        #expect(filled.lines.count == 3)
        #expect(filled.isPauseLine(at: 1))
    }

    @Test("Every gap becomes exactly one row, and nothing else changes")
    func oneRowPerGap() {
        // Five lines with three gaps between them.
        let lyrics = self.sheet([
            (0, 1_000, "One"),
            (5_000, 1_000, "Two"),
            (7_000, 1_000, "Three"),
            (12_000, 1_000, "Four"),
            (13_500, 1_000, "Five"),
        ])

        let filled = lyrics.withPauseInterludes()

        // 5 lines + 3 gaps: 1_000→5_000, 6_000→7_000 and 8_000→12_000. The 500 ms
        // between Four and Five is short of the threshold and gets no row.
        #expect(filled.lines.count == 8)
        #expect(filled.lines.filter { SyncedLyrics.isSilent($0) }.count == 3)
        #expect(filled.isPauseLine(at: 1))
        #expect(filled.isPauseLine(at: 3))
        #expect(filled.isPauseLine(at: 5))
        #expect(!filled.isPauseLine(at: 7))
    }

    @Test("The synthesized rows ascend and never overlap, so no line is drawn twice")
    func rowsAreOrderedAndNonOverlapping() {
        let lyrics = self.sheet([
            (0, 2_000, "One"),
            (4_500, 1_500, "Two"),
            (7_000, 1_000, "Three"),
            (15_000, 2_000, "Four"),
        ])

        let filled = lyrics.withPauseInterludes()

        #expect(filled.lines == filled.lines.sorted { $0.timeInMs < $1.timeInMs })
        for (earlier, later) in zip(filled.lines, filled.lines.dropFirst()) {
            #expect(earlier.timeInMs + earlier.duration <= later.timeInMs)
            // A zero or negative window is not a row, it is a line the highlight would
            // flicker onto.
            #expect(earlier.duration > 0)
        }
    }

    // MARK: - The sheet the display actually reads

    @Test("The row the highlight lands on during an interlude is the pause row")
    func highlightLandsOnTheSynthesizedPause() {
        let lyrics = self.sheet([(0, 1_000, "First"), (4_000, 1_000, "Second")])
            .withPauseInterludes()

        // Mid-gap: the pause row, not the line that just finished and not the next one.
        #expect(lyrics.currentLineIndex(at: 2_000) == 1)
        #expect(lyrics.pauseInterlude(at: 2_000)?.lineIndex == 1)

        // And the dots progress across it: thirds of the 3000 ms gap.
        #expect(lyrics.pauseDotStatuses(forLineAt: 1, at: 1_000) == [.active, .notSung, .notSung])
        #expect(lyrics.pauseDotStatuses(forLineAt: 1, at: 2_000) == [.sung, .active, .notSung])
        #expect(lyrics.pauseDotStatuses(forLineAt: 1, at: 3_000) == [.sung, .sung, .active])

        // Still the pause row on the last millisecond of the gap, and by its end the next
        // line has arrived.
        #expect(lyrics.currentLineIndex(at: 3_999) == 1)
        #expect(lyrics.currentLineIndex(at: 4_000) == 2)
    }

    @Test("The highlight leaves the pause row only when the next line is due")
    func highlightLeavesTheGapAtItsEnd() {
        let lyrics = self.sheet([(0, 1_000, "First"), (4_000, 1_000, "Second")])
            .withPauseInterludes()

        for timeMs in stride(from: 1_000, to: 4_000, by: 250) {
            let index = lyrics.currentLineIndex(at: timeMs)
            #expect(index == 1, "at \(timeMs) ms the highlight was on row \(index ?? -1)")
        }
    }

    // MARK: - The real path: Apple Music TTML

    /// A faithful fragment of the word-synced TTML Unison serves, with the same document
    /// shape the real thing has — the metadata, agent and songwriter elements included, so
    /// this also pins that their text never leaks into a lyric line. Its paragraphs are
    /// contiguous *within* each line and it has a 1527 ms interlude between the second and
    /// third, which is the shape that leaves the dots with nothing to render on.
    private static let wordSyncedTTML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="Word" xml:lang="en">
    <head><metadata><ttm:title>Autobahn</ttm:title><ttm:agent xml:id="v1" type="person"><ttm:name>Lead</ttm:name></ttm:agent><iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal" leadingSilence="0.260"><songwriters><songwriter>Kim Petras</songwriter><songwriter>Liam Hall</songwriter></songwriters></iTunesMetadata></metadata></head>
    <body dur="4:18.074"><div begin="0:03.574" end="0:16.909" itunes:songPart="Verse">
    <p begin="0:03.574" end="0:07.952" ttm:agent="v1"><span begin="0:03.574" end="0:03.855">Starin'</span> <span begin="0:03.855" end="0:04.138">at</span> <span begin="0:04.138" end="0:07.952">the</span></p>
    <p begin="0:07.952" end="0:12.473" ttm:agent="v1"><span begin="0:07.952" end="0:08.159">Freaks</span> <span begin="0:08.159" end="0:12.473">in</span></p>
    <p begin="0:14.000" end="0:16.909" ttm:agent="v1"><span begin="0:14.000" end="0:16.909">Maybe</span></p>
    </div></body></tt>
    """

    @Test("Word-synced TTML has no empty paragraph, so without the gaps there is nothing to dot")
    func wordSyncedTTMLHasNoEmptyParagraph() throws {
        let parsed = try #require(TTMLParser.parse(Self.wordSyncedTTML, source: "Unison"))

        #expect(parsed.lines.count == 3)
        #expect(parsed.lines.allSatisfy { !SyncedLyrics.isSilent($0) })
        #expect(parsed.lines.contains { ($0.words ?? []).count > 1 })
        #expect(parsed.lines[0].text == "Starin' at the")
        // Exactly the three paragraphs, with no metadata text among them.
        #expect(parsed.lines.map(\.timeInMs) == [3_574, 7_952, 14_000])
        // Which is the bug: nothing here is a pause line.
        #expect(!(0 ..< parsed.lines.count).contains { parsed.isPauseLine(at: $0) })
    }

    /// A `<p>` with no `begin`/`end` is placed by its own spans, and one with nothing in it at
    /// all is dropped.
    ///
    /// The line's declared window is state on the parser, and it is tempting to read the two
    /// untimed paragraphs below as inheriting the first paragraph's window — which would make
    /// the second of them a pause row pointing at a stretch of the song that is already over,
    /// i.e. exactly the spurious row the dots must not produce. They do not: `didStartElement`
    /// assigns the window from each new `<p>`'s attributes, writing `nil` when it declares
    /// neither. That is worth pinning, because the "is this a gap?" branch keys off exactly
    /// those two values being non-nil.
    private static let untimedParagraphTTML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tt xmlns="http://www.w3.org/ns/ttml"><body><div>
    <p begin="0:01.000" end="0:02.000"><span begin="0:01.000" end="0:02.000">First</span></p>
    <p><span begin="0:05.000" end="0:06.000">Untimed</span></p>
    <p></p>
    <p begin="0:09.000" end="0:10.000">Last</p>
    </div></body></tt>
    """

    @Test("A paragraph with no times of its own takes them from its own spans")
    func untimedParagraphDoesNotInherit() throws {
        let parsed = try #require(TTMLParser.parse(Self.untimedParagraphTTML, source: "Unison"))

        // The untimed paragraph is placed by its own first span, not the one before it, and
        // the untimed *empty* paragraph is dropped rather than turned into a pause row on
        // the previous paragraph's window.
        #expect(parsed.lines.count == 3)
        #expect(parsed.lines.map(\.timeInMs) == [1_000, 5_000, 9_000])
        #expect(parsed.lines.map(\.text) == ["First", "Untimed", "Last"])
        #expect(parsed.lines.allSatisfy { !SyncedLyrics.isSilent($0) })
        #expect(parsed.lines[1].duration == 4_000)
    }

    @Test("The interlude of a real word-synced document becomes a pause row")
    func wordSyncedTTMLGapBecomesPauseRow() throws {
        let parsed = try #require(TTMLParser.parse(Self.wordSyncedTTML, source: "Unison"))
        let filled = parsed.withPauseInterludes()

        #expect(filled.lines.count == 4)
        let pause = filled.lines[2]
        #expect(SyncedLyrics.isSilent(pause))
        #expect(pause.timeInMs == 12_473)
        #expect(pause.duration == 1_527)
        #expect(filled.isPauseLine(at: 2))
        // The lines around it are untouched, so the karaoke wipe loses nothing.
        #expect(filled.lines[1] == parsed.lines[1])
        #expect(filled.lines[3] == parsed.lines[2])
        #expect(filled.lines[3].words?.isEmpty == false)
    }

    // MARK: - A backing vocal that outlasts its own line

    /// A faithful fragment of a real Unison document, with the shape Apple Music writes when a
    /// backing vocal continues past the paragraph it sits under: the phrase's onsets lie *after*
    /// the paragraph's end, so it fills through the interlude the next paragraph's arrival leaves.
    ///
    /// Real numbers, from a played-and-cached sheet: `I'm sick, I'm sick` at 1:40.934 with
    /// `(High, the way that you're stuck in my head)` under it, its last word at 1:44.979, and
    /// the next paragraph at 1:45.753. The phrase therefore lands at 105029 ms, 2311 ms after
    /// the line's own end, while the pause row the gap produces starts at 102718 — and the
    /// highlight used to sit on those dots for that whole 2.3 s with the backing still sweeping.
    private static let lateBackgroundVocalTTML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="Word" xml:lang="en">
    <head><metadata><ttm:title>Limerence</ttm:title></metadata></head>
    <body dur="3:20.000"><div begin="1:40.934" end="1:46.661" itunes:songPart="Verse">
    <p begin="1:40.934" end="1:42.718" itunes:key="L1" ttm:agent="v1"><span begin="1:40.934" end="1:41.092">I'm</span> <span begin="1:41.092" end="1:41.615">sick,</span> <span begin="1:41.615" end="1:41.876">I'm</span> <span begin="1:41.876" end="1:42.718">sick</span> <span ttm:role="x-bg"><span begin="1:42.783">(High,</span> <span begin="1:43.061">the</span> <span begin="1:43.263">way</span> <span begin="1:43.604">that</span> <span begin="1:43.860">you're</span> <span begin="1:44.060">stuck</span> <span begin="1:44.414">in</span> <span begin="1:44.680">my</span> <span begin="1:44.979">head)</span></span></p>
    <p begin="1:45.753" end="1:46.661" itunes:key="L2" ttm:agent="v1"><span begin="1:45.753" end="1:45.946">I'm</span> <span begin="1:45.946" end="1:46.181">sick,</span> <span begin="1:46.181" end="1:46.416">I</span> <span begin="1:46.416" end="1:46.661">know</span></p>
    </div></body></tt>
    """

    @Test("A backing vocal that outlasts its line keeps the highlight off the dots")
    func lateBackingVocalHoldsTheHighlight() throws {
        let parsed = try #require(TTMLParser.parse(Self.lateBackgroundVocalTTML, source: "Unison"))
        // The display's own two passes, in its own order (`SyncedLyricsService.forDisplay`).
        let filled = parsed.convertingParenthesizedBackingVocals().withPauseInterludes()

        #expect(filled.lines.count == 3)
        let sung = filled.lines[0]
        #expect(sung.text == "I'm sick, I'm sick")
        #expect(sung.backgroundText == "High, the way that you're stuck in my head")

        // The rows are untouched by any of this: the pause still covers the whole gap, so the
        // scroll, the row statuses and the indices the display works with are all as they were.
        let pause = filled.lines[1]
        #expect(SyncedLyrics.isSilent(pause))
        #expect(pause.timeInMs == 102_718)
        #expect(pause.duration == 3_035)
        #expect(filled.isPauseLine(at: 1))

        // The backing phrase's last word lands at 105029: 2311 ms after the line's declared end.
        #expect(KaraokeFillModel.settleBoundaryMs(for: sung) == 105_029)

        // So the highlight is on the line being sung for every millisecond of that, rather than
        // on the dots underneath it while the phrase is still filling.
        for timeMs in stride(from: 102_718, to: 105_029, by: 100) {
            let index = KaraokeFillModel.highlightIndex(in: filled, at: timeMs)
            #expect(index == 0, "at \(timeMs) ms the highlight was on row \(index ?? -1)")
        }
        #expect(KaraokeFillModel.highlightIndex(in: filled, at: 105_028) == 0)

        // And it moves onto the pause when the phrase has landed, staying there until the next
        // line is due.
        #expect(KaraokeFillModel.highlightIndex(in: filled, at: 105_029) == 1)
        #expect(KaraokeFillModel.highlightIndex(in: filled, at: 105_752) == 1)
        #expect(KaraokeFillModel.highlightIndex(in: filled, at: 105_753) == 2)

        // The dots agree about when the pause began — they rest through the phrase and start with
        // the frame it lands on — so nothing on the row contradicts the line still being sung.
        #expect(filled.pauseInterlude(forLineAt: 1)?.startTimeMs == 105_029)
        #expect(filled.pauseDots(forLineAt: 1, at: 102_718).statuses == [.notSung, .notSung, .notSung])
        #expect(filled.pauseDots(forLineAt: 1, at: 105_028).statuses == [.notSung, .notSung, .notSung])
        #expect(filled.pauseDots(forLineAt: 1, at: 105_029).statuses == [.active, .notSung, .notSung])
        #expect(filled.pauseDots(forLineAt: 1, at: 105_753).statuses == [.sung, .sung, .sung])
    }

    // MARK: - The frame budget, which is what the sheet costs to draw

    @Test("At most three rows are ever on the display clock, gaps or no gaps")
    func liveRowsStayBounded() {
        let lyrics = self.sheet([
            (0, 2_000, "One"),
            (6_000, 2_000, "Two"),
            (12_000, 2_000, "Three"),
            (20_000, 2_000, "Four"),
        ]).withPauseInterludes()

        // Up to the end of the last line: past it nothing is being sung, which is
        // correctly no highlight at all rather than a second live row.
        let lastMs = lyrics.lines.last.map { $0.timeInMs + $0.duration } ?? 0
        for timeMs in stride(from: 0, to: lastMs, by: 50) {
            guard let current = KaraokeFillModel.highlightIndex(in: lyrics, at: timeMs) else {
                Issue.record("no highlight at \(timeMs) ms")
                continue
            }
            let live = lyrics.lines.indices.filter { index in
                KaraokeFillModel.isLiveRow(
                    lineIndex: index,
                    currentLineIndex: current,
                    line: lyrics.lines[index],
                    clockMs: Double(timeMs)
                )
            }
            // The line being sung, the one after it, and the one that has just finished.
            #expect(live.count <= 3, "\(live.count) rows were live at \(timeMs) ms: \(live)")
        }
    }

    // MARK: - Helpers

    private func sheet(_ lines: [(startMs: Int, duration: Int, text: String)]) -> SyncedLyrics {
        SyncedLyrics(
            lines: lines.map { SyncedLyricLine(timeInMs: $0.startMs, duration: $0.duration, text: $0.text, words: nil) },
            source: "UnitTest"
        )
    }
}
