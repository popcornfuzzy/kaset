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
        /// Playback position of the first frame.
        var startMs: Double = 1000
        /// How often this row redraws in the app.
        let framesPerSecond: Double
    }

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
            Scenario(name: "panel, current line, word-by-word   ", line: wordTimed, fontSize: 16, width: 248, spanMs: 1200, framesPerSecond: live),
            Scenario(name: "panel, current line, line-by-line    ", line: lineSynced, fontSize: 16, width: 248, spanMs: 1200, framesPerSecond: live),
            Scenario(name: "fullscreen, current line, word-by-word", line: wordTimed, fontSize: 36, width: 600, spanMs: 1200, framesPerSecond: live),
            Scenario(name: "fullscreen, current line, line-by-line ", line: lineSynced, fontSize: 36, width: 600, spanMs: 1200, framesPerSecond: live),
            // The line after the current one also redraws, on the same clock, so it is part
            // of the bill. Nothing on it moves until it becomes the current line.
            Scenario(name: "panel, next line (armed, untouched)  ", line: wordTimed, fontSize: 16, width: 248, spanMs: 0, startMs: -800, framesPerSecond: armed),
            Scenario(name: "fullscreen, next line (armed)        ", line: wordTimed, fontSize: 36, width: 600, spanMs: 0, startMs: -800, framesPerSecond: armed),
        ]

        var report: [String] = []
        var regressions: [String] = []
        var shareOfACore = 0.0

        for scenario in scenarios {
            let perFrame = self.liveFrames(scenario)
            let perSecond = perFrame * scenario.framesPerSecond
            shareOfACore += perSecond
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

        // A worst case that would be unacceptable as an animation budget in the harness's
        // pessimistic terms: one core just for lyrics.
        report.append("worst case (both surfaces animating): \(Self.format(shareOfACore / 10))% of a core")

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
        emphasis: Double = 1
    ) -> Double {
        let frames = 60
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

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
