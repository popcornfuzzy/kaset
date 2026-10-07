import Foundation
import Testing
@testable import Kaset

@Suite(.tags(.model))
struct SyncedLyricsPauseInterludeTests {
    @Test("Pause line is recognized as interlude")
    func pauseInterludeRecognized() {
        let lyrics = self.makeLyricsWithPause(duration: 1800)

        let interlude = lyrics.pauseInterlude(forLineAt: 1)

        #expect(interlude != nil)
        #expect(interlude?.lineIndex == 1)
        #expect(interlude?.startTimeMs == 1000)
        #expect(interlude?.endTimeMs == 2800)
    }

    @Test("Short empty lines are not treated as pause interludes")
    func shortPauseNotRecognized() {
        let lyrics = self.makeLyricsWithPause(duration: 500)

        let interlude = lyrics.pauseInterlude(forLineAt: 1)

        #expect(interlude == nil)
    }

    @Test("Dot statuses progress across interlude thirds")
    func dotStatusesProgressThroughPause() {
        let lyrics = self.makeLyricsWithPause(duration: 1800)

        #expect(lyrics.pauseDotStatuses(forLineAt: 1, at: 1000) == [.active, .notSung, .notSung])
        #expect(lyrics.pauseDotStatuses(forLineAt: 1, at: 1600) == [.sung, .active, .notSung])
        #expect(lyrics.pauseDotStatuses(forLineAt: 1, at: 2200) == [.sung, .sung, .active])
        #expect(lyrics.pauseDotStatuses(forLineAt: 1, at: 2800) == [.sung, .sung, .sung])
    }

    @Test("Current-time pause lookup returns active interlude")
    func pauseLookupAtCurrentTime() {
        let lyrics = self.makeLyricsWithPause(duration: 1800)

        let activeInterlude = lyrics.pauseInterlude(at: 1700)

        #expect(activeInterlude != nil)
        #expect(activeInterlude?.lineIndex == 1)
    }

    @Test("A pause begins when the row above stops sounding, not at the row's own timestamp")
    func pauseWaitsForTheRowAbove() {
        // The row above carries a backing phrase whose onset lies past its own end — the shape
        // Apple Music writes — so it is still filling when the sheet says the pause began.
        let lyrics = SyncedLyrics(
            lines: [
                SyncedLyricLine(
                    timeInMs: 0,
                    duration: 1_000,
                    text: "I'm sick",
                    words: [TimedWord(timeInMs: 0, word: "I'm"), TimedWord(timeInMs: 400, word: " sick")],
                    backgroundWords: [TimedWord(timeInMs: 1_200, word: " high", isBackground: true)]
                ),
                SyncedLyricLine(timeInMs: 1_000, duration: 3_000, text: "", words: nil),
                SyncedLyricLine(timeInMs: 4_000, duration: 1_000, text: "Next", words: nil),
            ],
            source: "UnitTest"
        )

        // The backing word's fill runs 1130…1250, so the row above is sounding until 1250 —
        // 250 ms after the pause row claims to start.
        #expect(KaraokeFillModel.settleBoundaryMs(for: lyrics.lines[0]) == 1_250)

        let interlude = lyrics.pauseInterlude(forLineAt: 1)
        #expect(interlude?.startTimeMs == 1_250)
        #expect(interlude?.endTimeMs == 4_000)
        #expect(interlude?.durationMs == 2_750)

        // So the dots rest while the backing is still filling, and begin the moment it lands:
        // nothing on the row contradicts the phrase that is still being sung.
        #expect(lyrics.pauseDots(forLineAt: 1, at: 1_000).statuses == [.notSung, .notSung, .notSung])
        #expect(lyrics.pauseDots(forLineAt: 1, at: 1_249).statuses == [.notSung, .notSung, .notSung])
        #expect(lyrics.pauseDots(forLineAt: 1, at: 1_250).statuses == [.active, .notSung, .notSung])

        // The row is still a pause by its own shape, whatever the row above is doing.
        #expect(lyrics.isPauseLine(at: 1))
        #expect(lyrics.isPauseLine(at: 0) == false)
    }

    private func makeLyricsWithPause(duration: Int) -> SyncedLyrics {
        SyncedLyrics(
            lines: [
                SyncedLyricLine(timeInMs: 0, duration: 1000, text: "Opening line", words: nil),
                SyncedLyricLine(timeInMs: 1000, duration: duration, text: "", words: nil),
                SyncedLyricLine(timeInMs: 1000 + duration, duration: 1400, text: "Next line", words: nil),
            ],
            source: "UnitTest"
        )
    }
}
