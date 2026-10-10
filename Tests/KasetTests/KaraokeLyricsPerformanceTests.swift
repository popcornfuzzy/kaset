import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Kaset

/// Measures what the karaoke animation costs while a song plays, so it can be made cheaper
/// without changing how it looks.
///
/// Each iteration builds and renders the line at a new display position, which is what a
/// `TimelineView` frame does: body evaluation, layout, masking, halo blur and text draw.
/// Absolute numbers are pessimistic — rasterizing into a bitmap is CPU work the app does on
/// the GPU — so the budget below is deliberately loose and the *report* is the useful part:
/// it attributes the cost to the layout, the halo and the fill machinery, and states the
/// total as a share of one CPU core at each row's own redraw rate.
@MainActor
@Suite(.tags(.model, .slow))
struct KaraokeLyricsPerformanceTests {
    /// Ceiling for one frame of one line. Loose on purpose: this guards the structure
    /// (a mask and a halo per word, a layout measured per frame, a row redrawing faster
    /// than it needs to) rather than the machine it runs on.
    private static let budgetMsPerFrame = 6.0

    private struct Scenario {
        let name: String
        let line: SyncedLyricLine
        let fontSize: CGFloat
        let width: CGFloat
        /// Milliseconds the frames span, so the run crosses several word boundaries.
        let spanMs: Double
        /// Decoration strength the surface this scenario stands for actually carries, so the harness
        /// prices the frame the app asks for rather than a heavier one it never draws: the lyrics
        /// panel passes 0.55 and the fullscreen player 1.0 (`SyncedLyricsDisplayView.emphasis`,
        /// `FullscreenNowPlayingView.karaokeEmphasis`).
        var emphasis: Double = 1
        /// Playback position of the first frame.
        var startMs: Double = 1000
        /// How often this row redraws in the app.
        let framesPerSecond: Double
    }

    /// The decoration strength the lyrics panel and the sidebar's sheets carry.
    private static let panelEmphasis = 0.55

    @Test("Live karaoke frames stay within budget")
    func liveFrameCost() throws {
        let timings = (0 ..< 8).map { index in
            TimedWord(timeInMs: index * 420, word: index == 0 ? "Sing" : " word\(index)")
        }
        let wordTimed = SyncedLyricLine(
            timeInMs: 0,
            duration: 3600,
            text: "Sing word1 word2 word3 word4 word5 word6 word7",
            words: timings
        )
        let lineSynced = SyncedLyricLine(
            timeInMs: 0,
            duration: 3600,
            text: "Sing word1 word2 word3 word4 word5 word6 word7",
            words: nil
        )
        let live = 1 / KaraokeFrameBudget.live
        let armed = 1 / KaraokeFrameBudget.armed

        let scenarios = [
            Scenario(name: "panel, current line, word-by-word   ", line: wordTimed, fontSize: 16, width: 248, spanMs: 1200, emphasis: Self.panelEmphasis, framesPerSecond: live),
            Scenario(name: "panel, current line, line-by-line    ", line: lineSynced, fontSize: 16, width: 248, spanMs: 1200, emphasis: Self.panelEmphasis, framesPerSecond: live),
            Scenario(name: "fullscreen, current line, word-by-word", line: wordTimed, fontSize: 36, width: 600, spanMs: 1200, framesPerSecond: live),
            Scenario(name: "fullscreen, current line, line-by-line ", line: lineSynced, fontSize: 36, width: 600, spanMs: 1200, framesPerSecond: live),
            // The line after the current one also redraws, on the same clock, so it is part
            // of the bill. Nothing on it moves until it becomes the current line.
            Scenario(name: "panel, next line (armed, untouched)  ", line: wordTimed, fontSize: 16, width: 248, spanMs: 0, emphasis: Self.panelEmphasis, startMs: -800, framesPerSecond: armed),
            Scenario(name: "fullscreen, next line (armed)        ", line: wordTimed, fontSize: 36, width: 600, spanMs: 0, startMs: -800, framesPerSecond: armed),
        ]

        var report: [String] = []
        var regressions: [String] = []
        var panelShare = 0.0
        var fullscreenShare = 0.0

        for scenario in scenarios {
            let perFrame = self.liveFrames(scenario)
            let perSecond = perFrame * scenario.framesPerSecond
            if scenario.name.hasPrefix("panel") {
                panelShare += perSecond
            } else {
                fullscreenShare += perSecond
            }
            // Milliseconds of drawing per second of playback, as a share of one core:
            // 1000 ms/s is a whole core, so 100 ms/s is 10%.
            report.append(
                "\(scenario.name): \(Self.format(perFrame)) ms/frame at \(Int(scenario.framesPerSecond)) fps = \(Self.format(perSecond / 10))% of a core"
            )
            if perFrame > Self.budgetMsPerFrame {
                regressions.append(
                    "\(scenario.name): \(Self.format(perFrame)) ms/frame exceeds the \(Self.format(Self.budgetMsPerFrame)) ms budget"
                )
            }
        }

        // Attribution on the expensive path: what the layout hoist and the halo are worth.
        let wordScenario = scenarios[0]
        report.append(
            "attribution — panel word-by-word, layout rebuilt per frame: \(Self.format(self.liveFrames(wordScenario, rebuildLayout: true))) ms/frame"
        )
        report.append(
            "attribution — panel word-by-word, no halo/feather/swell: \(Self.format(self.liveFrames(wordScenario, emphasis: 0))) ms/frame"
        )
        // And what the lift is worth on the same line: at the panel's own emphasis it is under a
        // quarter point of travel, so it is not drawn at all — this prices the same line at the
        // strength that does draw it.
        report.append(
            "attribution — panel word-by-word, lift drawn (emphasis 1): \(Self.format(self.liveFrames(wordScenario, emphasis: 1))) ms/frame"
        )

        // The pause row's dots. What is being drawn when the highlight is on a pause row is three
        // dots and a bounce; what was being *computed* was the question of when the silence began,
        // which is measured from the line above the row (`KaraokeFillModel.settleBoundaryMs`) — asked
        // on every frame of the bounce. The row holds one interlude and asks it for each frame's dots,
        // and this prices both ends of that.
        let dots = Self.pauseDotFrameCosts(lyrics: Self.pauseDotsSheet())
        report.append(
            "pause dots, interlude resolved once: \(Self.format(dots.resolved, places: 3)) ms/frame against \(Self.format(dots.perFrame, places: 3)) re-derived per frame"
        )

        // A worst case that would be unacceptable as an animation budget in the harness's
        // pessimistic terms: one core just for lyrics.
        //
        // The panel and the fullscreen player are the two surfaces that animate, and their sheets can
        // no longer animate **together**: presenting the player covers every other lyric sheet, and a
        // covered sheet draws no frames at all (`KaraokeFrameBudget.plan`) — the sidebar behind the
        // player used to keep singing at the full live rate. So the bill is the worse of the two, not
        // their sum, which is printed underneath for reference.
        report.append("worst case, one surface animating: \(Self.format(max(panelShare, fullscreenShare) / 10))% of a core")
        report.append("for reference, both surfaces summed (they cannot run together): \(Self.format((panelShare + fullscreenShare) / 10))% of a core")

        // The report is attached to a failure, so a regression arrives with the numbers
        // that explain it. `KARAOKE_PERF_REPORT=1 swift test --filter KaraokeLyricsPerformanceTests`
        // prints the numbers on a healthy run too (as a deliberately failing issue).
        let wantsReport = ProcessInfo.processInfo.environment["KARAOKE_PERF_REPORT"] == "1"
        if !regressions.isEmpty || wantsReport {
            let header = regressions.isEmpty ? "Karaoke frame cost:" : "Karaoke frame cost regressed:"
            Issue.record(
                Comment(rawValue: header + "\n" + (regressions + [""] + report).joined(separator: "\n"))
            )
        }
    }

    /// The cost of one display frame of the wipe, at one playback position after another.
    /// The layout is built once, the way the row builds it from its cache.
    private func liveFrames(
        _ scenario: Scenario,
        rebuildLayout: Bool = false,
        emphasis: Double? = nil
    ) -> Double {
        let frames = 60
        let emphasis = emphasis ?? scenario.emphasis
        let layout = KaraokeLineLayout(line: scenario.line, fontSize: scenario.fontSize)

        // Warm up so first-frame setup (font caches, layout) is not measured.
        for index in 0 ..< 5 {
            self.render(scenario, layout: layout, at: scenario.startMs + Double(index) * 16, emphasis: emphasis)
        }

        let started = DispatchTime.now()
        for index in 0 ..< frames {
            let ms = scenario.startMs + scenario.spanMs * Double(index) / Double(frames)
            let frameLayout = rebuildLayout
                ? KaraokeLineLayout(line: scenario.line, fontSize: scenario.fontSize)
                : layout
            self.render(scenario, layout: frameLayout, at: ms, emphasis: emphasis)
        }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        return elapsedMs / Double(frames)
    }

    private func render(
        _ scenario: Scenario,
        layout: KaraokeLineLayout,
        at displayTimeMs: Double,
        emphasis: Double
    ) {
        let view = KaraokeLyricsLineView(
            layout: layout,
            displayTimeMs: displayTimeMs,
            emphasis: emphasis
        )
        .frame(width: scenario.width, height: scenario.fontSize * 4, alignment: .topLeading)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        _ = renderer.cgImage
    }

    /// A sheet with a sung line and the pause that follows it, so a pause row has an interlude to
    /// show: nine lead words, so the line above has words to measure.
    private static func pauseDotsSheet() -> SyncedLyrics {
        SyncedLyrics(
            lines: [
                SyncedLyricLine(
                    timeInMs: 0,
                    duration: 4000,
                    text: "one two three four five six seven eight nine",
                    words: (0 ..< 9).map { index in
                        TimedWord(timeInMs: index * 430, word: index == 0 ? "one" : " word\(index)")
                    }
                ),
                SyncedLyricLine(timeInMs: 4000, duration: 6000, text: "", words: nil),
            ],
            source: "KaraokePauseDotsHarness"
        )
    }

    /// The cost of one frame of a pause row's dots, both ways: the interlude resolved once for the row
    /// (what the row does now) and re-derived from the line above on every frame (what it did).
    private static func pauseDotFrameCosts(lyrics: SyncedLyrics) -> (resolved: Double, perFrame: Double) {
        let frames = 600
        func positions(_ body: (Int) -> Void) -> Double {
            for index in 0 ..< 50 { body(index) }
            let started = DispatchTime.now()
            for index in 0 ..< frames { body(index) }
            return Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000 / Double(frames)
        }

        let perFrame = positions { index in
            _ = lyrics.pauseDots(forLineAt: 1, at: 4200 + index * 10)
        }
        let interlude = lyrics.pauseInterlude(forLineAt: 1)
        let resolved = positions { index in
            _ = SyncedLyrics.PauseDots(interlude: interlude, at: 4200 + index * 10)
        }
        return (resolved, perFrame)
    }

    private static func format(_ value: Double, places: Int = 2) -> String {
        String(format: "%.\(places)f", value)
    }
}
