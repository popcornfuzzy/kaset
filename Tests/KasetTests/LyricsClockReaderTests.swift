import AppKit
import SwiftUI
import Testing
@testable import Kaset

/// The 10 Hz playback stream stops at the lyric sheet, not at the surface around it.
///
/// The position arrives from the hidden WebView's lyrics poll ten times a second, and a sheet needs
/// it — but the surface a sheet sits in does not: a panel's glass, a column's artwork and cards, the
/// fullscreen player's blurred backdrop and transport controls do not change with playback. Reading
/// the stream in those bodies rebuilt all of them ten times a second to hand a sheet a number only
/// the sheet uses, and the fullscreen player is mounted for the whole session, so its share of that
/// ran whether or not it was on screen.
///
/// `Observation` tracks a property per view body, so this hosts the **real** reader next to a probe
/// that does not read the clock at all, publishes samples the way the poll does, and counts what was
/// rebuilt. The probe is the surface: if it is rebuilt by a sample, the surface is too.
@MainActor
@Suite(.tags(.model))
struct LyricsClockReaderTests {
    /// Advances the run loop so the hosted view actually renders.
    private func pump(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }
    }

    /// What the harness saw: how often each side of it was rebuilt, and what the sheet was handed.
    @MainActor
    private final class RebuildLog {
        /// Body evaluations of the probe: the surface around the sheet.
        private(set) var probeCount = 0
        /// Body evaluations of the sheet's stand-in, and the position each of them was handed.
        private(set) var sheetTimes: [Int] = []
        private(set) var sheetIsFullscreenPresented: [Bool] = []

        func recordProbe() { self.probeCount += 1 }

        func recordSheet(timeMs: Int, isFullscreenPresented: Bool) {
            self.sheetTimes.append(timeMs)
            self.sheetIsFullscreenPresented.append(isFullscreenPresented)
        }
    }

    /// Stands in for everything a lyric surface draws around its sheet — header, artwork, cards,
    /// footer — by being a view that reads no playback state and counts its own rebuilds.
    private struct SurfaceProbe: View {
        let log: RebuildLog

        var body: some View {
            let _ = self.log.recordProbe()
            Text("surface")
        }
    }

    /// A sheet's stand-in: it reports every position it is built with, which is what the sheet does
    /// with one (its rows draw from it, its clock is fed from it).
    private struct SheetProbe: View {
        let log: RebuildLog
        let timeMs: Int
        let isFullscreenPresented: Bool

        var body: some View {
            let _ = self.log.recordSheet(timeMs: self.timeMs, isFullscreenPresented: self.isFullscreenPresented)
            Text("\(self.timeMs)")
        }
    }

    private struct ClockReaderHarness: View {
        let playerService: PlayerService
        let log: RebuildLog

        var body: some View {
            VStack(spacing: 0) {
                SurfaceProbe(log: self.log)
                LyricsClockReader { currentTimeMs, _, isFullscreenPresented in
                    SheetProbe(log: self.log, timeMs: currentTimeMs, isFullscreenPresented: isFullscreenPresented)
                }
            }
            .environment(self.playerService)
        }
    }

    private func host(_ playerService: PlayerService, log: RebuildLog) -> (window: NSWindow, hosting: NSHostingView<ClockReaderHarness>) {
        let hosting = NSHostingView(rootView: ClockReaderHarness(playerService: playerService, log: log))
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
        return (window, hosting)
    }

    @Test("Playback samples rebuild the sheet and not the surface around it")
    func samplesRebuildTheSheetOnly() {
        let playerService = PlayerService()
        let log = RebuildLog()
        let window = self.host(playerService, log: log)
        defer { window.window.orderOut(nil) }

        self.pump(0.2)
        let settledProbeCount = log.probeCount
        #expect(settledProbeCount > 0, "the harness never drew its surface")
        #expect(log.sheetTimes.isEmpty == false, "the harness never drew its sheet")

        // Ten samples, the way the poll reports them, with the run loop pumped after each so the
        // hosted view actually updates rather than coalescing the whole stream into one pass.
        for step in 1 ... 10 {
            playerService.currentTimeMs = 10_000 + step * 100
            self.pump(0.05)
        }

        // The sheet was handed the stream...
        #expect(log.sheetTimes.last == 11_000, "the sheet was not handed the newest position")
        #expect(log.sheetTimes.contains(10_500), "the sheet skipped samples the poll reported")

        // ...and the surface around it was not rebuilt once, which is the whole point: it is the same
        // panel, the same glass, the same artwork, the same cards, ten times a second.
        #expect(log.probeCount == settledProbeCount, "the surface around the sheet was rebuilt by the clock stream")
    }

    @Test("A fullscreen presentation is not a reason to rebuild the surface behind it either")
    func fullscreenFlagStopsAtTheSheet() {
        let playerService = PlayerService()
        let log = RebuildLog()
        let window = self.host(playerService, log: log)
        defer { window.window.orderOut(nil) }

        self.pump(0.2)
        let settledProbeCount = log.probeCount

        // Presenting the fullscreen player is read by the sheet (it is what tells the sheet it is
        // covered), and by nothing above it.
        playerService.showFullscreenNowPlaying = true
        self.pump(0.1)
        #expect(log.sheetIsFullscreenPresented.last == true, "the sheet was not told the player is presented")
        playerService.showFullscreenNowPlaying = false
        self.pump(0.1)
        #expect(log.sheetIsFullscreenPresented.last == false, "the sheet was not told the player had left")

        #expect(log.probeCount == settledProbeCount, "the surface around the sheet was rebuilt by the fullscreen flag")
    }
}
