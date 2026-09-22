import AppKit
import SwiftUI
import Testing
@testable import Kaset

/// A lyric row's live→settled hand-off is a value change inside one view, not a replacement of it,
/// and a settled row stops drawing.
///
/// `KaraokeTimeSource` used to branch — a `TimelineView` while the row was live, a settled frame
/// otherwise. An `if`/`else` in a `ViewBuilder` builds `_ConditionalContent`, so the hand-off
/// *replaced* the row's subtree, in the same update that changes the row's status: the frame the
/// line that has just been sung starts leaving on. It also kept drawing a departed line's frozen
/// frame, scaled, until a trailing window expired.
///
/// Nothing offscreen can see either half of that: `ImageRenderer` draws one frame at model values
/// and never runs a timeline. So this hosts the row's time source in a window, pumps the run loop,
/// and counts how many times the row was handed a position to draw — which is what drawing a row
/// means here — and records the position it was handed.
@MainActor
@Suite(.tags(.model))
struct KaraokeRowHandoffTests {
    /// Every position the row has been asked to draw, and every identity its content has reported.
    @MainActor
    private final class DrawLog {
        private(set) var positions: [Double] = []
        /// Distinct content identities, in the order they first appeared. A `@State` value outlives
        /// re-renders but not a replaced subtree, so a second entry here means the hand-off tore the
        /// row's content down and built it again — which is what SwiftUI refuses to animate.
        private(set) var identities: [UUID] = []

        func record(_ displayTimeMs: Double, identity: UUID) {
            self.positions.append(displayTimeMs)
            if self.identities.last != identity { self.identities.append(identity) }
        }
    }

    /// A row whose only job is to be counted, and to say who it is.
    private struct CountingRow: View {
        let log: DrawLog
        let displayTimeMs: Double
        /// Survives re-renders and nothing else.
        @State private var identity = UUID()

        var body: some View {
            let _ = self.log.record(self.displayTimeMs, identity: self.identity)
            Text("\(Int(self.displayTimeMs))")
        }
    }

    /// Flips the row between live and settled, the way a line change does.
    @MainActor
    @Observable
    fileprivate final class Liveness {
        var isLive = true
    }

    private struct HandoffHarness: View {
        let liveness: Liveness
        let log: DrawLog
        let clock: LyricsPlaybackClock
        let line: SyncedLyricLine

        var body: some View {
            KaraokeTimeSource(
                line: self.line,
                words: KaraokeFillModel.words(for: self.line),
                status: self.liveness.isLive ? .current : .previous,
                isLive: self.liveness.isLive,
                clock: self.clock,
                minimumFrameInterval: KaraokeFrameBudget.live
            ) { displayTimeMs in
                CountingRow(log: self.log, displayTimeMs: displayTimeMs)
            }
            .frame(width: 300, height: 80, alignment: .topLeading)
        }
    }

    private static func line() -> SyncedLyricLine {
        SyncedLyricLine(
            timeInMs: 0,
            duration: 4000,
            text: "alpha bravo charlie",
            words: [
                TimedWord(timeInMs: 0, word: "alpha"),
                TimedWord(timeInMs: 1200, word: " bravo"),
                TimedWord(timeInMs: 2400, word: " charlie"),
            ]
        )
    }

    /// Advances the run loop for the given wall-clock time, so the hosted row actually renders.
    private func pump(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }
    }

    private func host(_ liveness: Liveness, log: DrawLog, clock: LyricsPlaybackClock) -> NSWindow {
        let hosting = NSHostingView(
            rootView: HandoffHarness(
                liveness: liveness,
                log: log,
                clock: clock,
                line: Self.line()
            )
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
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

    @Test("A live row is handed a new position every frame")
    func liveRowDrawsEveryFrame() {
        let liveness = Liveness()
        let log = DrawLog()
        let clock = LyricsPlaybackClock()
        clock.receive(LyricsClockSample(hostTime: Date(), timeMs: 10_000, isPlaying: true))
        let window = self.host(liveness, log: log, clock: clock)
        defer { window.orderOut(nil) }

        self.pump(0.3)

        // Enough frames to be the display link rather than one or two evaluations, and always
        // moving forwards: this is the row that carries the wipe.
        #expect(log.positions.count >= 8, "the live row was handed \(log.positions.count) frames in 300 ms")
        #expect(log.positions == log.positions.sorted())
        #expect((log.positions.last ?? 0) > (log.positions.first ?? 0))
        #expect(log.identities.count == 1, "the row's content was replaced while it was live")
    }

    @Test("A row that has settled is handed its settled frame once and then stops drawing")
    func settledRowStopsDrawing() {
        let liveness = Liveness()
        let log = DrawLog()
        let clock = LyricsPlaybackClock()
        clock.receive(LyricsClockSample(hostTime: Date(), timeMs: 10_000, isPlaying: true))
        let window = self.host(liveness, log: log, clock: clock)
        defer { window.orderOut(nil) }

        self.pump(0.3)
        let whileLive = log.positions.count
        #expect(whileLive >= 8, "the row was not live to begin with (\(whileLive) frames)")

        // The line change: the same update that makes this row the one that has just been sung.
        liveness.isLive = false
        self.pump(0.3)
        let afterSettling = log.positions.count

        // At most the one frame that hands it the settled position: the timeline is paused, so the
        // departure (scale, opacity, drift) is Core Animation animating a raster nothing is
        // redrawing. The row used to keep drawing here until a trailing window expired.
        #expect(afterSettling - whileLive <= 1, "the settled row drew \(afterSettling - whileLive) more frames")

        // And what it was handed on that one frame is the settled frame, not wherever the clock had
        // reached when the line changed: the frame the row freezes on is the frame it should have.
        let settled = KaraokeFillModel.staticTimeMs(for: .previous, words: KaraokeFillModel.words(for: Self.line()), line: Self.line())
        #expect(log.positions.last == settled)

        // And it kept its identity while it happened. This is the structural half, and the reason for
        // the paused timeline rather than an `if isLive … else …`: an `if`/`else` is
        // `_ConditionalContent`, so the hand-off *replaces* the row's content, and SwiftUI does not
        // animate a subtree it replaces — the line that has just been sung would have its departure
        // applied to a brand-new subtree on the frame it starts to leave.
        #expect(log.identities.count == 1, "the hand-off replaced the row's content (\(log.identities.count) identities)")
        #expect(KaraokeFillModel.words(for: Self.line()).allSatisfy { $0.fill(at: settled) == 1 })
    }
}
