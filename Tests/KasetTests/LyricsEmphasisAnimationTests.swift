import AppKit
import SwiftUI
import Testing
@testable import Kaset

/// The line that has just been sung must leave from a frame it has already finished being sung on,
/// and leave smoothly.
///
/// Two defects lived here. The highlight used to be taken from the **scroll** lead — the panel fed
/// `currentLineIndex(at: timeMs + scrollLookaheadMs)` into the rows' status — so a line began to
/// dim, shrink and recede 120 ms before its last word had finished filling: it never reached its
/// sung state before it started to leave, which is what "it doesn't animate smoothly into the sung
/// state" was. And the row kept redrawing that frozen frame, inside a changing scale, until a
/// trailing window expired.
///
/// Nothing offscreen can observe an implicit animation or a redraw — `ImageRenderer` draws one frame
/// at model values and never runs a timeline — so this hosts the **real** panel in a window,
/// publishes playback samples at the 10 Hz the WebView's lyrics poll reports at, and reads the
/// rendered pixels between them. The line that leaves is given a deliberately wide text, so its right
/// edge is the widest ink on screen and can be followed frame by frame: a spring shows as a series of
/// intermediate widths, a snap as one. Its last word fills late, so how far the bright part of that
/// row reaches across it says whether the line was still being sung as it left.
///
/// **Sampling floor.** Reading a frame out of a hosted `NSView` costs ~60 ms on this machine (AppKit's
/// offscreen caching path, not the drawing), so the trace runs at roughly 15 Hz however tightly the
/// loop is written. The departure assertions below are shaped for that: they ask that the change takes
/// several *sampled* frames to arrive and that no single sample carries most of it, which a change
/// applied in one step cannot satisfy, rather than pretending to follow a 0.42 s spring at 60 Hz.
@MainActor
@Suite(.tags(.model))
struct LyricsEmphasisAnimationTests {
    /// Advances the run loop for the given wall-clock time, so the hosted view actually renders
    /// frames instead of jumping straight to the end state.
    private func pump(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }
    }

    // MARK: - Recording

    /// One frame of the hosted panel, in device pixels.
    private struct TracedFrame {
        /// The playback position the panel had been handed for this frame.
        let timeMs: Int
        /// Left-most and right-most inked columns of the whole sheet.
        let minX: Int
        let maxX: Int
        /// How far the bright (sung) part of the sheet's widest row reaches across that row, 0...1.
        /// A row that is still being sung has a dim run at its right where the fill has not got to.
        let sungReach: Double
    }

    /// What a departure looked like, frame by frame.
    private struct DepartureTrace {
        let frames: [TracedFrame]
        let flipTimeMs: Int
        /// Right-most inked column while the wide line was still the one being sung.
        let fullWidth: Int
        /// The first frame whose line had begun to shrink, if it began at all.
        let departureIndex: Int?

        /// The frame the departure was first seen on. The previous frame is the last one the line was
        /// still showing at its sung size, which is the frame it was still being sung on.
        var lastFrameBeforeLeaving: TracedFrame? {
            guard let departureIndex, departureIndex > 0 else { return nil }
            return self.frames[departureIndex - 1]
        }

        /// Widths from the departure onwards, and the total it moved.
        var widthsAfterDeparture: [Int] {
            guard let departureIndex else { return [] }
            return self.frames[departureIndex...].map(\.maxX)
        }
    }

    /// Records a frame while the run loop is pumped for `seconds`.
    private func record(_ view: NSView, at timeMs: Int, for seconds: Double) -> [TracedFrame] {
        var frames: [TracedFrame] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
            if let frame = Self.capture(view, at: timeMs) {
                frames.append(frame)
            }
        }
        return frames
    }

    /// The panel's pixels, reduced to what the departure moves: the extent of the widest row's ink,
    /// and how much of that row is bright rather than at the dim base.
    private static func capture(_ view: NSView, at timeMs: Int) -> TracedFrame? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.bitmapData, rep.samplesPerPixel >= 4 else { return nil }

        let samples = rep.samplesPerPixel
        let rowBytes = rep.bytesPerRow
        var columnAlpha = [UInt8](repeating: 0, count: rep.pixelsWide)
        for y in 0 ..< rep.pixelsHigh {
            let row = data + y * rowBytes
            for x in 0 ..< rep.pixelsWide where row[x * samples + 3] > columnAlpha[x] {
                columnAlpha[x] = row[x * samples + 3]
            }
        }

        let inked = columnAlpha.indices.filter { columnAlpha[$0] > 20 }
        guard let minX = inked.first, let maxX = inked.last, maxX > minX else { return nil }

        // The bright end of the sheet's widest row. Three quarters of the brightest ink on screen:
        // the line that is leaving is still at full opacity when it leaves, and the rows around it
        // are not.
        let peak = Int(columnAlpha.max() ?? 0)
        let lit = columnAlpha.indices.last { $0 >= minX && Int(columnAlpha[$0]) >= peak * 3 / 4 } ?? minX

        return TracedFrame(
            timeMs: timeMs,
            minX: minX,
            maxX: maxX,
            sungReach: Double(min(max(lit, minX), maxX) - minX) / Double(maxX - minX)
        )
    }

    /// Plays into the wide line and across the moment the highlight leaves it, recording what the
    /// panel drew on the way.
    private func traceDeparture(sheet: SyncedLyrics, playFromMs: Int, flipTimeMs: Int) -> DepartureTrace {
        let driver = EmphasisDriver()
        let window = self.host(driver, lyrics: sheet)
        guard let hosting = window.contentView as? NSHostingView<EmphasisHarness> else {
            Issue.record("the harness did not install its content view")
            return DepartureTrace(frames: [], flipTimeMs: flipTimeMs, fullWidth: 0, departureIndex: nil)
        }
        defer { window.orderOut(nil) }

        self.pump(0.4)
        var frames: [TracedFrame] = []

        // Inside the wide line, so it is the line being sung at full scale.
        driver.currentTimeMs = playFromMs
        self.pump(0.6)
        frames += self.record(hosting, at: playFromMs, for: 0.05)

        // Then the 100 ms steps the WebView's lyrics poll reports at, up to the sample the highlight
        // moves on. One capture per window is enough here: nothing on this row moves while it is the
        // line being sung, and all this stretch has to establish is the width it holds.
        var time = playFromMs + 100
        while time < flipTimeMs {
            driver.currentTimeMs = time
            self.pump(0.1)
            if let frame = Self.capture(hosting, at: time) {
                frames.append(frame)
            }
            time += 100
        }

        // The change itself, and the departure it starts.
        driver.currentTimeMs = flipTimeMs
        frames += self.record(hosting, at: flipTimeMs, for: 0.6)

        let fullWidth = frames.filter { $0.timeMs < flipTimeMs }.map(\.maxX).max() ?? 0
        let tolerance = max(2, fullWidth / 400)
        let departureIndex = frames.firstIndex { $0.maxX <= fullWidth - tolerance }

        return DepartureTrace(
            frames: frames,
            flipTimeMs: flipTimeMs,
            fullWidth: fullWidth,
            departureIndex: departureIndex
        )
    }

    /// What a departure has to look like, at the sampling rate this harness can manage.
    private func expectSmoothDeparture(_ trace: DepartureTrace) -> [Int] {
        guard trace.fullWidth > 0, let departure = trace.departureIndex else {
            Issue.record("the departing line never moved, so there was no departure to measure")
            return []
        }

        let widths = trace.frames[departure...].map(\.maxX)
        let total = trace.fullWidth - (widths.last ?? trace.fullWidth)
        let steps = zip(widths, widths.dropFirst()).map { $0 - $1 }

        // The change arrives over several sampled frames rather than in one…
        #expect(Set(widths).count >= 2, "only \(Set(widths).count) distinct widths across the departure")

        // …the first frame it is seen on is nowhere near where it ends up (a step change would be
        // there already)…
        #expect(
            (widths.first ?? 0) - (widths.last ?? 0) >= max(2, total / 5),
            "the departure was most of the way over on its first frame"
        )

        // …no single sampled frame carries most of it…
        #expect((steps.max() ?? 0) <= max(4, total * 4 / 5), "a single frame moved \((steps.max() ?? 0))px of \(total)")

        // …it only ever shrinks (a spring that overshoots would be visible as growth)…
        #expect((steps.min() ?? 0) >= -1, "the line grew back mid-departure")

        // …and the line really did scale down, so this is not a no-op test.
        #expect(total >= 5, "the line shrank by only \(total)px")

        return widths
    }

    // MARK: - Sheets

    /// Nine two-second lines, the fourth of them far wider than the others, so the row under test is
    /// the widest ink on screen whether it is the line being sung or the line that has left.
    private static func sheet(wideLineWords: [TimedWord]?) -> SyncedLyrics {
        SyncedLyrics(
            lines: (0 ..< 9).map { index in
                SyncedLyricLine(
                    timeInMs: index * 2000,
                    duration: 2000,
                    text: index == 4 ? "W WWWWWWWWWWWWWWW" : "alpha bravo",
                    words: wideLineWords.map { index == 4 ? $0 : Self.narrowLineWords(startMs: index * 2000) }
                )
            },
            source: "EmphasisAnimationTest"
        )
    }

    private static func narrowLineWords(startMs: Int) -> [TimedWord] {
        [
            TimedWord(timeInMs: startMs, word: "alpha"),
            TimedWord(timeInMs: startMs + 1000, word: " bravo"),
        ]
    }

    /// The wide line's word timings: a one-letter first word, and a last word that fills only in the
    /// line's last 180 ms (its ramp ends 40 ms before the line does, from the release tail). A last
    /// word that fills that late is what makes "was this line still being sung when it left?" a
    /// question the pixels can answer: the highlight leaves at 10000 ms, and it used to leave at
    /// 9880 ms, where this word is still 65% swept.
    private static let wideLineWords = [
        TimedWord(timeInMs: 8000, word: "W"),
        TimedWord(timeInMs: 9850, word: " WWWWWWWWWWWWWWW"),
    ]

    /// Hosts the real panel in an offscreen window, so the widest row is visible from the first frame
    /// and the auto-scroll cannot change which row is being measured.
    private func host(_ driver: EmphasisDriver, lyrics: SyncedLyrics) -> NSWindow {
        let hosting = NSHostingView(rootView: EmphasisHarness(driver: driver, lyrics: lyrics))
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 320)
        hosting.wantsLayer = true
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderBack(nil)
        return window
    }

    // MARK: - The line that leaves has finished being sung

    @Test("The line that has just been sung has finished filling before it starts to leave")
    func departureBeginsOnAFullySungFrame() {
        let wideLine = Self.sheet(wideLineWords: Self.wideLineWords).lines[4]
        let layout = KaraokeLineLayout(line: wideLine, fontSize: 16)
        let rowWidth = zip(layout.textWidths, layout.gaps).reduce(CGFloat(0)) { $0 + $1.0 + $1.1 }
        #expect(rowWidth < 288, "the harness's wide line must stay on one row for the trace to mean anything")

        let trace = self.traceDeparture(
            sheet: Self.sheet(wideLineWords: Self.wideLineWords),
            playFromMs: 8200,
            flipTimeMs: 10_000
        )
        guard let lastSungFrame = trace.lastFrameBeforeLeaving else {
            Issue.record("the departing line never moved, so there was no departure to measure")
            return
        }

        // The last word of this line fills until 9960 ms and the highlight leaves at 10000 ms, so on
        // the frame the line starts to leave it has nothing left to fill. Moving the highlight on
        // 120 ms earlier — which is what the panel did — is a line that starts to dim and shrink with
        // its last word still 65% swept, which is the bug this pins.
        #expect(
            lastSungFrame.sungReach >= 0.93,
            "the departing line was only \(lastSungFrame.sungReach.formatted(.number.precision(.fractionLength(2)))) sung when it left"
        )

        // And the departure is still a spring.
        _ = self.expectSmoothDeparture(trace)
    }

    // MARK: - The departure is smooth for a whole-line lyric too

    @Test("The line that has just been sung scales down over several frames instead of snapping")
    func leavingLineScalesDownSmoothly() {
        let trace = self.traceDeparture(
            sheet: Self.sheet(wideLineWords: nil),
            playFromMs: 8200,
            flipTimeMs: 10_000
        )

        _ = self.expectSmoothDeparture(trace)
    }
}

// MARK: - Harness

/// The playback position the harness publishes, in the 100 ms steps the lyrics poll uses.
@MainActor
@Observable
fileprivate final class EmphasisDriver {
    var currentTimeMs = 0
}

@MainActor
private struct EmphasisHarness: View {
    let driver: EmphasisDriver
    let lyrics: SyncedLyrics

    var body: some View {
        SyncedLyricsDisplayView(
            lyrics: self.lyrics,
            currentTimeMs: self.driver.currentTimeMs,
            isPlaying: true,
            onSeek: { _ in }
        )
    }
}
