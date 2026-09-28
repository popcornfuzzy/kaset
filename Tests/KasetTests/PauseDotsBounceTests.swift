import Foundation
import Testing
@testable import Kaset

/// The three pause dots bounce, and the bounce belongs to the interlude rather than to the
/// wall clock.
///
/// The dot that is moving used to read a display-refresh clock directly, so its rise was in
/// phase with how long the app had been running rather than with anything on screen. A dot took
/// over from the one before it wherever that clock happened to be: a 600 ms interlude caught it
/// half-way up a rise, and a 30-second one kept the same 720 ms period for forty bounces — one
/// rate for gaps three orders of magnitude apart.
///
/// The bounce is now a value of the interlude's own progress (see
/// `SyncedLyrics.PauseInterlude.dotLift`), which makes every dot arrive at rest, leave at rest,
/// and take a number of bounces chosen from the length of its turn.
@Suite(.tags(.model))
struct PauseDotsBounceTests {
    /// A pause of the given length, alone in its sheet, at 1000 ms.
    private func pause(durationMs: Int) -> SyncedLyrics {
        SyncedLyrics(
            lines: [
                SyncedLyricLine(timeInMs: 0, duration: 1_000, text: "Before", words: nil),
                SyncedLyricLine(timeInMs: 1_000, duration: durationMs, text: "", words: nil),
                SyncedLyricLine(timeInMs: 1_000 + durationMs, duration: 1_000, text: "After", words: nil),
            ],
            source: "UnitTest"
        )
    }

    /// The whole number of bounces one dot's turn holds.
    private static func bounces(durationMs: Int) -> Int {
        let turnMs = Double(durationMs) / 3.0
        return max(1, Int((turnMs / SyncedLyrics.PauseInterlude.targetBounceMs).rounded()))
    }

    @Test("The dot is at rest when its turn begins, when it ends, and at every bounce between")
    func restsAtEveryCycleBoundary() {
        // A long interlude: seventeen bounces in one turn, every one of them starting and
        // ending with the dot down.
        let durationMs = 17_000
        let lyrics = self.pause(durationMs: durationMs)
        let turnMs = Double(durationMs) / 3.0
        let bounces = Self.bounces(durationMs: durationMs)

        for turn in 0 ..< 3 {
            let turnStart = 1_000 + Double(turn) * turnMs
            for boundary in 0 ... bounces {
                let timeMs = Int((turnStart + Double(boundary) * turnMs / Double(bounces)).rounded())
                let lift = lyrics.pauseDots(forLineAt: 1, at: timeMs).lift
                #expect(lift < 0.02, "the dot was \(lift) up at the start of a bounce, \(timeMs) ms")
            }
        }
    }

    @Test("The dot is at its highest half-way through a bounce")
    func peaksMidBounce() {
        let durationMs = 9_000
        let lyrics = self.pause(durationMs: durationMs)
        let bounces = Self.bounces(durationMs: durationMs)
        let periodMs = Double(durationMs) / 3.0 / Double(bounces)

        for bounce in 0 ..< bounces {
            let peak = 1_000 + Double(bounce) * periodMs + periodMs / 2
            let lift = lyrics.pauseDots(forLineAt: 1, at: Int(peak.rounded())).lift
            #expect(lift > 0.9, "the dot only reached \(lift) at the top of its bounce")
        }
    }

    /// The rise never steps: it is drawn on a row that redraws per frame, so a jump between two
    /// frames *is* the stutter the animation is supposed to not have.
    @Test("The rise is continuous, and stays continuous where one dot takes over from the next")
    func riseIsContinuous() {
        let lyrics = self.pause(durationMs: 3_000)

        var previous = 0.0
        for step in stride(from: 1_000.0, through: 4_000.0, by: 16) {
            let lift = lyrics.pauseDots(forLineAt: 1, at: Int(step)).lift
            #expect(abs(lift - previous) < 0.15, "the dot jumped by \(abs(lift - previous)) at \(step) ms")
            previous = lift
        }
    }

    /// One bounce takes about `targetBounceMs` whatever the interlude is — that is the whole
    /// point: the same dot does not flutter over 600 ms of silence and crawl over thirty
    /// seconds of it.
    @Test("How fast a bounce is comes from the interlude's length, not from the clock")
    func bounceRateSuitesTheLength() {
        for durationMs in [600, 900, 1_800, 3_000, 6_000, 9_000, 31_845] {
            let turnMs = Double(durationMs) / 3.0
            let periodMs = turnMs / Double(Self.bounces(durationMs: durationMs))

            // A whole number of bounces fits in the turn, so the dot is down at both ends...
            #expect(abs(periodMs * Double(Self.bounces(durationMs: durationMs)) - turnMs) < 0.001)

            // ...and the one it is doing is about three quarters of a second long, which is
            // what keeps a long gap from crawling and a short one from fluttering. A turn
            // shorter than one bounce gets exactly one, which is as slow as it can be.
            if turnMs >= SyncedLyrics.PauseInterlude.targetBounceMs {
                #expect(periodMs >= 375, "a bounce took \(periodMs) ms at \(durationMs) ms of silence")
                #expect(periodMs <= 1_125, "a bounce took \(periodMs) ms at \(durationMs) ms of silence")
            } else {
                #expect(Self.bounces(durationMs: durationMs) == 1)
            }
        }

        // A gap only just long enough for the dots gets one unhurried pulse rather than a
        // flutter: its 200 ms turn is one bounce.
        #expect(Self.bounces(durationMs: 600) == 1)
        // And a gap of half a minute does not bounce forty times inside one dot's turn.
        #expect(Self.bounces(durationMs: 31_845) == 14)
    }

    @Test("The dot does not move before its interlude, and is at rest after it")
    func stillOutsideTheInterlude() {
        let lyrics = self.pause(durationMs: 1_800)

        for timeMs in [0, 500, 999, 1_000 + 1_800, 5_000, 60_000] {
            let dots = lyrics.pauseDots(forLineAt: 1, at: timeMs)
            #expect(dots.lift == 0, "the dot was \(dots.lift) up at \(timeMs) ms")
        }

        // Before: nothing lit. After: all three sung and still.
        #expect(lyrics.pauseDots(forLineAt: 1, at: 900).statuses == [.notSung, .notSung, .notSung])
        #expect(lyrics.pauseDots(forLineAt: 1, at: 2_900).statuses == [.sung, .sung, .sung])
    }

    /// The row hands the dots two different positions over its life — the display clock while it
    /// is the line being sung, and a settled frame once it is not — and both have to agree, or
    /// the dots jump on the frame the highlight moves on.
    @Test("The settled frame of a pause has no bounce in it, so the hand-off cannot jump")
    func settledFrameMatchesTheEndOfTheBounce() {
        let lyrics = self.pause(durationMs: 1_800)
        let line = lyrics.lines[1]

        let settled = Int(KaraokeFillModel.staticTimeMs(for: .previous, line: line))
        let upcoming = Int(KaraokeFillModel.staticTimeMs(for: .upcoming, line: line))

        #expect(lyrics.pauseDots(forLineAt: 1, at: settled).lift == 0)
        #expect(lyrics.pauseDots(forLineAt: 1, at: upcoming).lift == 0)

        // On the last live frame of the interlude the moving dot is already back down, with only
        // its own dot still to land — so the hand-off is one dot's opacity fading, not anything
        // moving, and the frame the row freezes on is the frame it was already showing.
        let lastLive = lyrics.pauseDots(forLineAt: 1, at: line.timeInMs + line.duration - 1)
        #expect(lastLive.lift < 0.01)
        #expect(lastLive.statuses == [.sung, .sung, .active])
        #expect(lyrics.pauseDots(forLineAt: 1, at: settled).statuses == [.sung, .sung, .sung])
    }

    @Test("A line that is not a pause has no dots to bounce")
    func nonPauseHasNoDots() {
        let lyrics = self.pause(durationMs: 1_800)

        #expect(lyrics.pauseDots(forLineAt: 0, at: 500) == .resting)
        #expect(lyrics.pauseDots(forLineAt: 2, at: 5_000) == .resting)

        // And a gap too short for the dots is left resting rather than flashing.
        let short = self.pause(durationMs: 400)
        #expect(short.pauseDots(forLineAt: 1, at: 1_200) == .resting)
    }
}
