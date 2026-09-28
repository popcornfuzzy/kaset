import Foundation
import Testing
@testable import Kaset

/// A row takes the display clock when something on it can change, and not a moment earlier.
///
/// The line *after* the one being sung used to run on the clock for the whole of the line before
/// it. Every frame it drew in that time was the frame already on screen — a line that has not
/// started renders every word unsung, which is the same picture from the clock and off it — so
/// it redrew a heavy row thirty times a second to produce nothing. On a sheet of word-synced
/// lines with backing vocals under most of them that is a third of the animation's cost spent on
/// identical frames, which is what this pins shut.
@Suite(.tags(.model))
struct KaraokeRowArmingTests {
    private static func line(startMs: Int, durationMs: Int, wordCount: Int, backingFrom: Int? = nil) -> SyncedLyricLine {
        let words = (0 ..< wordCount).map { index in
            TimedWord(timeInMs: startMs + index * 500, word: index == 0 ? "first" : " word\(index)")
        }
        let backing = backingFrom.map { from in
            [TimedWord(timeInMs: from, word: "Oh", isBackground: true)]
        }
        return SyncedLyricLine(
            timeInMs: startMs,
            duration: durationMs,
            text: words.map(\.word).joined(),
            words: words,
            backgroundWords: backing
        )
    }

    @Test("The next row is not on the clock while the line before it is still being sung")
    func nextRowWaitsForItsOwnFirstRamp() {
        let current = Self.line(startMs: 0, durationMs: 4_000, wordCount: 8)
        let next = Self.line(startMs: 10_000, durationMs: 4_000, wordCount: 8)

        // Most of the current line: the next row's picture is the one it already drew.
        for clockMs in [0, 1_000, 4_000, 8_000, 9_000] {
            #expect(
                !KaraokeFillModel.isLiveRow(lineIndex: 1, currentLineIndex: 0, line: next, clockMs: Double(clockMs)),
                "the next row took the clock at \(clockMs) ms"
            )
        }

        // Its own first ramp opens one attack lead before its first word, and the row takes the
        // clock a margin before that, so a late sample cannot have it first seen part-filled.
        let armed = KaraokeFillModel.armBoundaryMs(for: next)
        #expect(armed == 10_000 - KaraokeTiming.standard.attackLeadMs - KaraokeTiming.standard.armLeadMs)
        #expect(KaraokeFillModel.isLiveRow(lineIndex: 1, currentLineIndex: 0, line: next, clockMs: armed))
        #expect(KaraokeFillModel.isLiveRow(lineIndex: 1, currentLineIndex: 0, line: next, clockMs: armed + 1))
        #expect(!KaraokeFillModel.isLiveRow(lineIndex: 1, currentLineIndex: 0, line: next, clockMs: armed - 1))
    }

    @Test("A backing vocal that starts the row pulls it onto the clock early")
    func backingVocalArmsTheRow() {
        // The lead does not come in until 5 s, but the backing vocal is already there at 3 s.
        let line = Self.line(startMs: 5_000, durationMs: 4_000, wordCount: 4, backingFrom: 3_000)
        let armed = KaraokeFillModel.armBoundaryMs(for: line)

        #expect(armed == 3_000 - KaraokeTiming.standard.attackLeadMs - KaraokeTiming.standard.armLeadMs)
        #expect(KaraokeFillModel.isLiveRow(lineIndex: 1, currentLineIndex: 0, line: line, clockMs: armed))
        #expect(!KaraokeFillModel.isLiveRow(lineIndex: 1, currentLineIndex: 0, line: line, clockMs: armed - 1))
    }

    @Test("A row with no words at all, like a pause, is armed at its own start")
    func silentRowIsArmedAtItsStart() {
        let pause = SyncedLyricLine(timeInMs: 8_000, duration: 2_000, text: "", words: nil)

        let armed = KaraokeFillModel.armBoundaryMs(for: pause)
        #expect(armed == 8_000 - KaraokeTiming.standard.attackLeadMs - KaraokeTiming.standard.armLeadMs)
        #expect(KaraokeFillModel.isLiveRow(lineIndex: 1, currentLineIndex: 0, line: pause, clockMs: armed))
        #expect(!KaraokeFillModel.isLiveRow(lineIndex: 1, currentLineIndex: 0, line: pause, clockMs: armed - 1))
    }

    @Test("The row being sung is always on the clock, and the one that has finished holds it until its content lands")
    func currentAndSettlingRowsKeepTheClock() {
        let current = Self.line(startMs: 5_000, durationMs: 4_000, wordCount: 4)

        // The line being sung, whatever the clock says: it carries the wipe.
        #expect(KaraokeFillModel.isLiveRow(lineIndex: 1, currentLineIndex: 1, line: current, clockMs: 5_000))

        // The one that has just finished holds it until its own content has landed, and no
        // longer — a backing word that outlasts the lead is what that boundary exists for.
        let settle = KaraokeFillModel.settleBoundaryMs(for: current)
        #expect(KaraokeFillModel.isLiveRow(lineIndex: 0, currentLineIndex: 1, line: current, clockMs: settle - 1))
        #expect(!KaraokeFillModel.isLiveRow(lineIndex: 0, currentLineIndex: 1, line: current, clockMs: settle))

        // Rows further out are never on the clock.
        let far = Self.line(startMs: 30_000, durationMs: 4_000, wordCount: 4)
        #expect(!KaraokeFillModel.isLiveRow(lineIndex: 3, currentLineIndex: 0, line: far, clockMs: 30_000))
    }

    /// The frames the change stops drawing are frames it had already drawn.
    ///
    /// This is what makes the saving free rather than a trade: a row that has not reached its own
    /// first ramp renders every word unsung, and `staticTimeMs` hands it the position just before
    /// that ramp — so the settled frame *is* the live frame, and dropping the frames in between
    /// cannot change a pixel.
    @Test("Every word of a not-yet-started row is untouched on both clocks")
    func theFramesDroppedAreTheFramesAlreadyDrawn() {
        let line = Self.line(startMs: 9_000, durationMs: 4_000, wordCount: 6, backingFrom: 9_200)

        let settled = KaraokeFillModel.staticTimeMs(for: .upcoming, line: line)
        let justBefore = KaraokeFillModel.armBoundaryMs(for: line) - 1
        #expect(justBefore < 9_000 - KaraokeTiming.standard.attackLeadMs)

        for words in [KaraokeFillModel.words(for: line), KaraokeFillModel.backgroundWords(for: line)] {
            #expect(!words.isEmpty)
            for word in words {
                #expect(word.fill(at: settled) == 0)
                #expect(word.fill(at: justBefore) == 0)
                // Nothing decorative either: a word with no fill has no glow and no lift, so
                // there is nothing on the row that a frame of the clock would change.
                #expect(word.glowStrength(at: settled) == 0)
                #expect(word.glowStrength(at: justBefore) == 0)
                for character in KaraokeFillModel.characters(for: word, weightedBy: []) {
                    #expect(character.swell(at: justBefore) == 0)
                }
            }
        }
    }
}
