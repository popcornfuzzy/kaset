import Foundation
import Testing
@testable import Kaset

// MARK: - LyricsPlaybackClockTests

/// The karaoke highlight is driven by a 10 Hz WebView poll, so the clock's job is to
/// make that stream look continuous: advance every frame, absorb sample jitter by
/// changing speed instead of jumping, snap on seeks, and freeze when paused.
@Suite(.tags(.model))
struct LyricsPlaybackClockTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 1000)

    @Test("A 10 Hz sample stream renders as continuous motion")
    func interpolatesBetweenSamples() throws {
        let clock = LyricsPlaybackClock()
        clock.receive(LyricsClockSample(hostTime: Self.start, timeMs: 0, isPlaying: true))

        var positions: [Double] = []
        for frame in 1 ... 60 {
            let date = Self.start.addingTimeInterval(Double(frame) / 60)
            if frame % 6 == 0 {
                clock.receive(
                    LyricsClockSample(hostTime: date, timeMs: frame * 1000 / 60, isPlaying: true)
                )
            }
            positions.append(clock.advance(to: date))
        }

        #expect(positions == positions.sorted())
        let steps = zip(positions, positions.dropFirst()).map { $1 - $0 }
        // Every frame moves the fill a frame's worth: no stalls, no jumps.
        #expect(steps.allSatisfy { $0 > 5 && $0 < 30 })
        let last = try #require(positions.last)
        #expect(abs(last - 1000) < 40)
    }

    @Test("A late sample slows the clock instead of jumping it")
    func absorbsLateSample() throws {
        let clock = LyricsPlaybackClock()
        clock.receive(LyricsClockSample(hostTime: Self.start, timeMs: 0, isPlaying: true))

        // One second of accurate 10 Hz samples, rendered at 60 fps.
        for step in 1 ... 10 {
            for frame in 0 ..< 6 {
                let date = Self.start.addingTimeInterval(Double((step - 1) * 6 + frame) / 60)
                clock.advance(to: date)
            }
            let sampleDate = Self.start.addingTimeInterval(Double(step) / 10)
            clock.receive(LyricsClockSample(hostTime: sampleDate, timeMs: step * 100, isPlaying: true))
        }

        let beforeLateSample = clock.displayPositionMs
        // The video was already at 850 ms when this message was read; it reached the
        // app 150 ms late. The display clock is ahead of the sample, not wrong.
        let lateDate = Self.start.addingTimeInterval(1.0)
        clock.receive(LyricsClockSample(hostTime: lateDate, timeMs: 850, isPlaying: true))

        var positions: [Double] = []
        for frame in 1 ... 6 {
            positions.append(clock.advance(to: lateDate.addingTimeInterval(Double(frame) / 60)))
        }

        #expect(positions == positions.sorted())
        let first = try #require(positions.first)
        let biggestStep = zip([beforeLateSample] + positions, positions).map { $1 - $0 }.max() ?? 0
        #expect(first >= beforeLateSample - 1)
        #expect(biggestStep < 30)

        // And it catches back up once samples are accurate again.
        for step in 11 ... 30 {
            for frame in 0 ..< 6 {
                let date = Self.start.addingTimeInterval(Double((step - 1) * 6 + frame) / 60)
                clock.advance(to: date)
            }
            let sampleDate = Self.start.addingTimeInterval(Double(step) / 10)
            clock.receive(LyricsClockSample(hostTime: sampleDate, timeMs: step * 100, isPlaying: true))
        }
        #expect(abs(clock.displayPositionMs - 3000) < 60)
    }

    @Test("A seek snaps the clock rather than slewing to it")
    func snapsOnSeek() {
        let clock = LyricsPlaybackClock()
        clock.receive(LyricsClockSample(hostTime: Self.start, timeMs: 5000, isPlaying: true))
        clock.advance(to: Self.start.addingTimeInterval(1.0 / 60))

        clock.receive(LyricsClockSample(hostTime: Self.start, timeMs: 60000, isPlaying: true))

        // Jumped to the new position at once, instead of crawling through 55 seconds
        // of lyric sheet at 1.4x.
        #expect(clock.displayPositionMs == 60000)
        #expect(clock.advance(to: Self.start.addingTimeInterval(2.0 / 60)) < 60040)
    }

    @Test("A new track resets the clock")
    func resetsForNewTrack() {
        let clock = LyricsPlaybackClock()
        clock.receive(LyricsClockSample(hostTime: Self.start, timeMs: 180000, isPlaying: true))
        clock.advance(to: Self.start)

        clock.reset()
        clock.receive(LyricsClockSample(hostTime: Self.start, timeMs: 0, isPlaying: true))

        #expect(clock.advance(to: Self.start.addingTimeInterval(1.0 / 60)) < 20)
    }

    @Test("Pausing freezes the clock at the paused position")
    func freezesWhenPaused() throws {
        let clock = LyricsPlaybackClock()
        clock.receive(LyricsClockSample(hostTime: Self.start, timeMs: 0, isPlaying: true))
        for frame in 1 ... 60 {
            clock.advance(to: Self.start.addingTimeInterval(Double(frame) / 60))
        }

        // The poll reports the same position while paused, so the pause stops the
        // clock from extrapolating past where the listener actually stopped.
        let pauseDate = Self.start.addingTimeInterval(1.0)
        clock.receive(LyricsClockSample(hostTime: pauseDate, timeMs: 1000, isPlaying: false))

        var positions: [Double] = []
        for frame in 1 ... 120 {
            positions.append(clock.advance(to: pauseDate.addingTimeInterval(Double(frame) / 60)))
        }

        // Frozen at the paused position, within a frame of it, and not creeping on
        // (the clock never runs backwards, so it stops rather than rewinds).
        let settled = try #require(positions.last)
        #expect(abs(settled - 1000) < 25)
        #expect(abs(settled - positions[2]) < 2)
    }

    @Test("Display position does not depend on the display's frame rate")
    func isFrameRateIndependent() throws {
        let samples = (0 ... 20).map { step in
            LyricsClockSample(
                hostTime: Self.start.addingTimeInterval(Double(step) / 10),
                timeMs: step * 100,
                isPlaying: true
            )
        }

        func run(fps: Double) throws -> Double {
            let clock = LyricsPlaybackClock()
            clock.receive(try #require(samples.first))
            for frame in 1 ... Int(2 * fps) {
                let elapsed = Double(frame) / fps
                let date = Self.start.addingTimeInterval(elapsed)
                if frame % Int(fps / 10) == 0, let sample = samples[safe: Int(elapsed * 10)] {
                    clock.receive(sample)
                }
                clock.advance(to: date)
            }
            return clock.displayPositionMs
        }

        let atSixty = try run(fps: 60)
        let atOneTwenty = try run(fps: 120)
        #expect(abs(atSixty - atOneTwenty) < 10)
    }
}

// MARK: - KaraokeFillModelTests

/// Word timings are onsets: the fill has to lead each onset slightly, land before the
/// next one, and — for lyrics no provider word-timed — still sweep the line.
@Suite(.tags(.model))
struct KaraokeFillModelTests {
    private static func wordTimedLine() -> SyncedLyricLine {
        SyncedLyricLine(
            timeInMs: 0,
            duration: 1500,
            text: "one two three",
            words: [
                TimedWord(timeInMs: 0, word: "one"),
                TimedWord(timeInMs: 500, word: " two"),
                TimedWord(timeInMs: 1000, word: " three"),
            ]
        )
    }

    @Test("Word timings become fill spans with an attack lead and a release tail")
    func wordTimingsBecomeSpans() {
        let words = KaraokeFillModel.words(for: Self.wordTimedLine())

        #expect(words.count == 3)
        #expect(words.map(\.text) == ["one", "two", "three"])
        #expect(words.map(\.isNewWord) == [true, true, true])

        // The first word leads its onset; the second lands before the third begins.
        #expect(words[0].fillStartMs == -70)
        #expect(words[0].fillEndMs == 460)
        #expect(words[1].fillStartMs == 430)
        #expect(words[1].fillEndMs == 960)
        #expect(words.map(\.fillStartMs) == words.map(\.fillStartMs).sorted())

        // The last word ends with the line rather than running past it.
        #expect(words[2].fillEndMs == 1460)
    }

    @Test("A word fills across its own span")
    func wordFillsAcrossItsSpan() {
        let span = KaraokeFillModel.words(for: Self.wordTimedLine())[0]

        #expect(span.fill(at: -1000) == 0)
        #expect(span.fill(at: span.fillStartMs) == 0)
        #expect(span.fill(at: span.fillEndMs) == 1)
        #expect(span.fill(at: span.fillEndMs + 1000) == 1)
        #expect(abs(span.fill(at: 195) - 0.5) < 0.01)

        // Monotone across the span.
        let samples = stride(from: span.fillStartMs, through: span.fillEndMs, by: 25).map { span.fill(at: $0) }
        #expect(samples == samples.sorted())
    }

    @Test("A long gap between onsets settles instead of crawling")
    func longGapSettles() {
        let line = SyncedLyricLine(
            timeInMs: 0,
            duration: 9000,
            text: "wait",
            words: [TimedWord(timeInMs: 0, word: "wait"), TimedWord(timeInMs: 8000, word: " now")]
        )
        let words = KaraokeFillModel.words(for: line)

        // The ramp is capped, so the edge lands instead of crawling through the gap.
        #expect(words[0].fillStartMs == -70)
        #expect(words[0].fillEndMs == 1160)
        #expect(words[1].fillStartMs == 7930)
    }

    @Test("Syllables of one word stay one word")
    func gluedSyllablesAreNotNewWords() {
        let line = SyncedLyricLine(
            timeInMs: 0,
            duration: 900,
            text: "beautiful",
            words: [
                TimedWord(timeInMs: 0, word: "beau"),
                TimedWord(timeInMs: 200, word: "ti"),
                TimedWord(timeInMs: 400, word: "ful"),
            ]
        )
        let words = KaraokeFillModel.words(for: line)

        #expect(words.map(\.text) == ["beau", "ti", "ful"])
        #expect(words.map(\.isNewWord) == [true, false, false])
    }

    @Test("A line without word timings is one fill unit, not invented words")
    func lineWithoutWordTimingsIsOneUnit() {
        let line = SyncedLyricLine(timeInMs: 1000, duration: 3000, text: "a bb ccc", words: nil)
        let words = KaraokeFillModel.words(for: line)

        // The provider timed the line, not its words: the line stays whole.
        #expect(words.count == 1)
        #expect(words[0].text == "a bb ccc")

        // Filling from the attack lead to just before the next line.
        #expect(words[0].fillStartMs == 930)
        #expect(words[0].fillEndMs == 3960)
        #expect(words[0].fill(at: 930) == 0)
        #expect(words[0].fill(at: 3960) == 1)
        #expect(abs(words[0].fill(at: (930 + 3960) / 2) - 0.5) < 0.01)
    }

    @Test("A line-synced lyric appears at its start and then stays lit")
    func lineAppearsAtItsStart() {
        let line = SyncedLyricLine(timeInMs: 1000, duration: 3000, text: "a line", words: nil)
        let word = KaraokeFillModel.words(for: line)[0]

        // Nothing before the line, and on screen shortly after it starts.
        #expect(word.appearProgress(at: 900) == 0)
        #expect(word.appearProgress(at: 930) == 0)
        #expect(word.appearProgress(at: 1030) > 0.1)
        #expect(word.appearProgress(at: 1130) == 1)

        // Lit for the rest of the line rather than brightening across it, which is what
        // makes the words legible while they are being sung.
        #expect(word.appearProgress(at: 2000) == 1)
        #expect(word.appearProgress(at: 3960) == 1)
        #expect(word.appearProgress(at: 5000) == 1)

        // The halo arrives with the line and settles to a soft residue.
        #expect(word.haloStrength(at: 900) == 0)
        #expect(word.haloStrength(at: 1130) > 0.9)
        #expect(word.haloStrength(at: 3000) < 0.35)
    }

    @Test("A line is sung for its whole length, so its fill is not capped")
    func lineFillIsNotCapped() {
        let line = SyncedLyricLine(timeInMs: 0, duration: 9000, text: "a long held line", words: nil)
        let word = KaraokeFillModel.words(for: line)[0]

        #expect(word.durationMs > KaraokeTiming.standard.maximumFillMs)
        #expect(word.fillEndMs == 8960)
    }

    @Test("The swell envelope is zero before a word and eases in from its own start")
    func swellEasesInFromTheWordStart() {
        let span = KaraokeFillModel.words(for: Self.wordTimedLine())[0]

        // Nothing swells before the word's own ramp begins, which is what lets the
        // next line run on the clock without ever being seen mid-swell.
        #expect(span.swell(at: span.fillStartMs) == 0)
        #expect(span.swell(at: span.fillStartMs - 500) == 0)

        // Rising, peaked in the middle, settled by the end.
        #expect(span.swell(at: span.fillStartMs + 10) < 0.05)
        #expect(span.swell(at: span.fillStartMs + 40) < span.swell(at: span.fillStartMs + 130))
        #expect(span.swell(at: span.fillEndMs - 10) < 0.05)
        #expect(span.swell(at: span.fillEndMs) == 0)
        #expect(span.swell(at: span.fillEndMs + 500) == 0)

        let middle = (span.fillStartMs + span.fillEndMs) / 2
        #expect(span.swell(at: middle) > 0.9)

        let samples = stride(from: span.fillStartMs, through: span.fillEndMs, by: 10)
            .map { span.swell(at: $0) }
        #expect(samples.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test("A short word still has time to swell")
    func shortWordSwells() {
        let line = SyncedLyricLine(
            timeInMs: 0,
            duration: 400,
            text: "a b",
            words: [TimedWord(timeInMs: 0, word: "a"), TimedWord(timeInMs: 60, word: " b")]
        )
        let span = KaraokeFillModel.words(for: line)[0]
        let peak = stride(from: span.fillStartMs, through: span.fillEndMs, by: 2)
            .map { span.swell(at: $0) }
            .max() ?? 0

        #expect(peak > 0.9)
        #expect(span.swell(at: span.fillEndMs) == 0)
    }

    @Test("A wordless line has no words to render")
    func blankLineHasNoWords() {
        let line = SyncedLyricLine(timeInMs: 0, duration: 2000, text: "   ", words: nil)
        #expect(KaraokeFillModel.words(for: line).isEmpty)
    }

    @Test("Finished lines read as fully sung and upcoming lines as untouched")
    func staticTimesReadAsSettled() {
        let line = Self.wordTimedLine()
        let previous = KaraokeFillModel.staticTimeMs(for: .previous, line: line)
        let upcoming = KaraokeFillModel.staticTimeMs(for: .upcoming, line: line)

        #expect(KaraokeFillModel.words(for: line).allSatisfy { $0.fill(at: previous) == 1 })
        #expect(KaraokeFillModel.words(for: line).allSatisfy { $0.fill(at: upcoming) == 0 })

        // A wordless gap still reads as finished, so its pause dots show as sung.
        let gap = SyncedLyricLine(timeInMs: 1000, duration: 3000, text: "", words: nil)
        #expect(KaraokeFillModel.staticTimeMs(for: .previous, line: gap) == 4000)
    }

    @Test("A line that has just finished keeps running until the clock is past its end")
    func trailingLineKeepsRunning() {
        func isLive(_ lineIndex: Int, _ currentLineIndex: Int?, _ lineEndMs: Double?, _ clockMs: Double) -> Bool {
            KaraokeFillModel.isLiveRow(
                lineIndex: lineIndex,
                currentLineIndex: currentLineIndex,
                lineEndMs: lineEndMs,
                clockMs: clockMs
            )
        }

        // The line being sung and the line after it always run on the clock.
        #expect(isLive(5, 5, 10_000, 0))
        #expect(isLive(6, 5, 12_000, 0))

        // The line that just finished keeps running until the clock is past its end, so
        // its switch to a settled frame lands on a frame that looks identical — the swap
        // that follows its status change must not replace its subtree mid-transition (that
        // is what made the line snap down instead of scaling down).
        #expect(isLive(4, 5, 9_000, 8_500))
        #expect(isLive(4, 5, 9_000, 9_100))
        #expect(!isLive(4, 5, 9_000, 9_200))

        // Anything further back is settled, with no clock time involved at all.
        #expect(!isLive(3, 5, 7_000, 8_500))

        // Before the first highlight is known, nothing runs.
        #expect(!isLive(0, nil, 1_000, 0))

        // A line with no end time (a wordless gap) never lingers.
        #expect(!isLive(4, 5, nil, 0))
    }

    @Test("The redraw budgets buy smoothness where it can be seen and nowhere else")
    func frameBudgetsAreOrderedForCost() {
        // The line being sung: the only row anybody is watching move.
        #expect(KaraokeFrameBudget.live < KaraokeFrameBudget.armed)
        // The line after it: filled by the same clock, but nothing on it moves yet.
        #expect(KaraokeFrameBudget.armed < KaraokeFrameBudget.covered)
        // Covered by the fullscreen player: still advanced, just not drawn for anybody.
        // Never slower than one frame per playback sample, or the clock would drift behind
        // the samples it corrects against (a frame is capped at 100 ms of playback).
        #expect(KaraokeFrameBudget.covered <= 0.1)
        // Reduce Motion keeps the fill but drops the decorative motion.
        #expect(KaraokeFrameBudget.reducedMotion > KaraokeFrameBudget.armed)
        // A paused song has a frozen fill: its frames only exist to take up a sample
        // correction or a seek, so they are far apart but never slower than 50 ms.
        #expect(KaraokeFrameBudget.paused > KaraokeFrameBudget.live)
        #expect(KaraokeFrameBudget.paused <= 0.05)
    }

    @Test("The fill ease is monotone between 0 and 1")
    func fillEaseIsMonotone() {
        #expect(KaraokeFillModel.ease(clamped: -0.5) == 0)
        #expect(KaraokeFillModel.ease(clamped: 0) == 0)
        #expect(KaraokeFillModel.ease(clamped: 1) == 1)
        #expect(KaraokeFillModel.ease(clamped: 1.5) == 1)
        #expect(abs(KaraokeFillModel.ease(clamped: 0.5) - 0.5) < 0.0001)

        let samples = stride(from: 0.0, through: 1.0, by: 0.05).map { KaraokeFillModel.ease(clamped: $0) }
        #expect(samples == samples.sorted())
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        self.indices.contains(index) ? self[index] : nil
    }
}
