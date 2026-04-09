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
