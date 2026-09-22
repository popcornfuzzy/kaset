import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Kaset

/// Renders the karaoke line offscreen and inspects its pixels, so the things the
/// timing model cannot see — the fill actually landing where the clock says, word
/// gaps, the soft leading edge, and wrapping — are covered without running the app.
@MainActor
@Suite(.tags(.model))
struct KaraokeLyricsRenderTests {
    /// Alpha a glyph carries before it has been sung: the dim base layer.
    private static let dimAlpha: Double = 0.32 * 255
    /// Alpha a glyph carries once sung.
    private static let sungAlpha = 255.0

    @Test("Unsung words are dim but visible, and a filled word fills no further than its timing")
    func fillFollowsTheClock() throws {
        let line = SyncedLyricLine(
            timeInMs: 0,
            duration: 1000,
            text: "MMMM",
            words: [TimedWord(timeInMs: 0, word: "MMMM")]
        )

        let unsung = try Self.columnAlphas(line: line, at: -500, fontSize: 40)
        let atHalf = try Self.columnAlphas(line: line, at: 480, fontSize: 40)
        let early = try Self.columnAlphas(line: line, at: 150, fontSize: 40)
        let late = try Self.columnAlphas(line: line, at: 850, fontSize: 40)
        let sung = try Self.columnAlphas(line: line, at: 5000, fontSize: 40)

        // Before the word: dim, and never bright.
        let unsungPeak = try #require(unsung.max())
        #expect(abs(Double(unsungPeak) - Self.dimAlpha) < 12)

        // The fill advances monotonically with the clock.
        let earlyFill = Self.sungFraction(of: early)
        let halfFill = Self.sungFraction(of: atHalf)
        let lateFill = Self.sungFraction(of: late)
        #expect(earlyFill < halfFill)
        #expect(halfFill < lateFill)
        #expect(halfFill > 0.4 && halfFill < 0.75)
        #expect(lateFill > halfFill + 0.15)

        // Sung: no dim tail left behind. Glyph edges are anti-aliased, so coverage
        // is measured on the bulk of the ink rather than on every boundary column.
        let sungInk = sung.filter { $0 > 20 }
        let bright = sungInk.count { Double($0) > Self.sungAlpha - 15 }
        #expect(Double(bright) / Double(sungInk.count) > 0.8)
    }

    @Test("The leading edge is feathered rather than a hard step")
    func leadingEdgeIsFeathered() throws {
        let line = SyncedLyricLine(
            timeInMs: 0,
            duration: 1000,
            text: "MMMM",
            words: [TimedWord(timeInMs: 0, word: "MMMM")]
        )
        let columns = try Self.columnAlphas(line: line, at: 480, fontSize: 40)

        // Columns part-way between the dim and sung alpha are the halo riding the edge.
        let partial = columns.filter { $0 > 120 && $0 < 235 }
        #expect(partial.count >= 3)

        // Reduce Motion drops the decorative edge but keeps the fill itself.
        let flat = try Self.columnAlphas(line: line, at: 480, fontSize: 40, emphasis: 0)
        let flatPartial = flat.filter { $0 > 120 && $0 < 235 }
        #expect(flatPartial.count < partial.count)
    }

    @Test("Line-synced lyrics appear as one unit instead of faking word timings")
    func lineSyncedLyricsAppearAsOneUnit() throws {
        let lineSynced = SyncedLyricLine(timeInMs: 0, duration: 1000, text: "alpha bravo", words: nil)
        let wordTimed = SyncedLyricLine(
            timeInMs: 0,
            duration: 1000,
            text: "alpha bravo",
            words: [TimedWord(timeInMs: 0, word: "alpha"), TimedWord(timeInMs: 500, word: " bravo")]
        )

        let appearing = try Self.columnAlphas(line: lineSynced, at: 30, fontSize: 40, width: 400)
        let midLine = try Self.columnAlphas(line: lineSynced, at: 480, fontSize: 40, width: 400)
        let lateLine = try Self.columnAlphas(line: lineSynced, at: 900, fontSize: 40, width: 400)
        let wordAtMidLine = try Self.columnAlphas(line: wordTimed, at: 480, fontSize: 40, width: 400)

        // It arrives over a short ramp at the line's start...
        #expect(Self.inkedMedian(of: appearing[0...]) < Self.inkedMedian(of: midLine[0...]))

        // ...and is then lit for the rest of the line, not brightening across it.
        #expect(Self.inkedMedian(of: midLine[0...]) > 200)
        #expect(Self.inkedMedian(of: lateLine[0...]) > 200)

        // Lit evenly, with no invented word edges: an even line reads as one line.
        let lineHalves = Self.wordSplitMedians(of: midLine)
        #expect(abs(lineHalves.left - lineHalves.right) < 30)

        // A word-timed line at the same moment is genuinely split: the first word is
        // sung, the next is still waiting its turn.
        let wordHalves = Self.wordSplitMedians(of: wordAtMidLine)
        #expect(wordHalves.left > wordHalves.right + 60)
    }

    @Test("Line-synced lyrics still carry the halo")
    func lineSyncedLyricsGetTheGlow() throws {
        let line = SyncedLyricLine(timeInMs: 0, duration: 1000, text: "alpha bravo", words: nil)

        let withGlow = try Self.columnAlphas(line: line, at: 480, fontSize: 40, width: 400)
        let withoutGlow = try Self.columnAlphas(line: line, at: 480, fontSize: 40, width: 400, emphasis: 0)

        #expect(Self.haloReach(withGlow: withGlow, withoutGlow: withoutGlow) > 4)
    }

    @Test("The glow blooms past the word's box instead of being cut off at it")
    func glowIsNotClippedToTheWordBox() throws {
        let line = SyncedLyricLine(
            timeInMs: 0,
            duration: 1000,
            text: "MM",
            words: [TimedWord(timeInMs: 0, word: "MM")]
        )

        // Fill well under way, so the halo is at full strength.
        let withGlow = try Self.columnAlphas(line: line, at: 700, fontSize: 40)
        let withoutGlow = try Self.columnAlphas(line: line, at: 700, fontSize: 40, emphasis: 0)

        let glyphEnd = try #require(withoutGlow.indices.last { withoutGlow[$0] > 3 })

        // The halo reaches well past the glyphs it was blurred from. A halo masked
        // inside the text box stops dead at the box, a pixel or two past the ink.
        #expect(Self.haloReach(withGlow: withGlow, withoutGlow: withoutGlow) > 4)

        // And past the glyph edge the halo only tapers — the glyph's own anti-aliased
        // edge steps by ~55 alpha, so anything sharper out here is a cut.
        let haloEnd = try #require(withGlow.indices.last { withGlow[$0] > 3 })
        #expect(haloEnd > glyphEnd + 3)
        let profile = withGlow[(glyphEnd + 3) ... haloEnd]
        let steepestDrop = zip(profile, profile.dropFirst())
            .map { Int($0) - Int($1) }
            .max() ?? 0
        #expect(steepestDrop < 30)
    }

    /// The frame a word completes on is an ordinary frame of the wipe.
    ///
    /// Two things used to land on it, both measured here. The glow was a function of the fill,
    /// so it was still at full strength on that frame and then disappeared with the word's mask.
    /// And the emphasis was a *scale*, and SwiftUI rasterizes text at the scale it is asked for:
    /// the swell's release re-rasterized the word on nearly every frame and snapped hardest on
    /// the frame it returned to its resting size — a 1.08 step where an ordinary frame is 0.03.
    /// That is only a word-synced problem (a line-synced line has no word swell), and that frame
    /// lands 40 ms before the line ends, in the middle of the line's own scale-down, which is
    /// what made the line that had just finished look like it jumped in place. Both are gone:
    /// this frame is now the same size as the fill's own step.
    @Test("A word completing is an ordinary frame, not a jump")
    func wordCompletionDoesNotPop() throws {
        let line = SyncedLyricLine(
            timeInMs: 0,
            duration: 2000,
            text: "MMMM",
            words: [TimedWord(timeInMs: 0, word: "MMMM")]
        )
        let word = KaraokeFillModel.words(for: line)[0]

        func frame(at time: Double) throws -> RenderedImage {
            try Self.render(line: line, at: time, fontSize: 40, width: 320, height: 70)
        }

        let beforeCompletion = try frame(at: word.fillEndMs - 10)
        let atCompletion = try frame(at: word.fillEndMs)
        let afterCompletion = try frame(at: word.fillEndMs + 10)
        // What the same transition costs when nothing decorative is drawn at all: the last
        // column of the word's ink filling in.
        let plainBefore = try Self.render(line: line, at: word.fillEndMs - 10, fontSize: 40, width: 320, height: 70, emphasis: 0)
        let plainAt = try Self.render(line: line, at: word.fillEndMs, fontSize: 40, width: 320, height: 70, emphasis: 0)
        let plain = Self.meanChannelDelta(plainBefore, plainAt)

        // The decoration adds nothing to this frame. A hard bound as well as the relative
        // one, because the relative one cannot see a uniformly worse baseline.
        let completion = Self.meanChannelDelta(beforeCompletion, atCompletion)
        #expect(completion < plain + 0.1, "completing a word cost \(completion) against a plain \(plain)")
        #expect(completion < 0.35, "completing a word moved the frame as much as a glow popping off or a word re-rasterising")

        // And nothing happens once it has: the word is finished and settled.
        #expect(Self.meanChannelDelta(atCompletion, afterCompletion) == 0)
    }

    /// The emphasis on the word being sung must not resize its text.
    ///
    /// A scale is the obvious way to express "this word is lifting", and it is the wrong one:
    /// SwiftUI re-rasterizes scaled text on every frame, so a scaled word steps and then snaps as
    /// it settles. The lift is a translation, so the glyphs keep their raster — which shows up
    /// here as the word's ink covering exactly the same columns at full emphasis as at none.
    @Test("The word being sung lifts instead of resizing")
    func emphasisLiftsRatherThanScales() throws {
        let raised = try Self.renderWord(fill: 0.5, swell: 1, glow: 1)
        let resting = try Self.renderWord(fill: 0.5, swell: 0, glow: 1)

        let raisedInk = try #require(Self.inkColumnRange(of: raised))
        let restingInk = try #require(Self.inkColumnRange(of: resting))
        #expect(abs(raisedInk.lowerBound - restingInk.lowerBound) <= 1)
        #expect(abs(raisedInk.upperBound - restingInk.upperBound) <= 1)

        // The lift does move the word, so the emphasis is still doing something.
        let raisedRows = try #require(Self.inkRowRange(of: raised))
        let restingRows = try #require(Self.inkRowRange(of: resting))
        #expect(raisedRows.lowerBound < restingRows.lowerBound)
    }

    @Test("Words keep the spacing between them")
    func wordsKeepTheirSpacing() throws {
        let line = SyncedLyricLine(
            timeInMs: 0,
            duration: 1500,
            text: "aa bb",
            words: [TimedWord(timeInMs: 0, word: "aa"), TimedWord(timeInMs: 500, word: " bb")]
        )
        let columns = try Self.columnAlphas(line: line, at: -500, fontSize: 40)

        let gap = Self.longestGap(in: columns)
        #expect(gap >= 5)

        // A syllable split gets no gap, so one word never looks like two.
        let glued = SyncedLyricLine(
            timeInMs: 0,
            duration: 1500,
            text: "aaaa",
            words: [TimedWord(timeInMs: 0, word: "aa"), TimedWord(timeInMs: 500, word: "aa")]
        )
        let gluedColumns = try Self.columnAlphas(line: glued, at: -500, fontSize: 40)
        #expect(Self.longestGap(in: gluedColumns) < gap)
    }

    @Test("A long line wraps to the margin without indenting the wrapped row")
    func longLineWrapsToTheMargin() throws {
        let line = SyncedLyricLine(
            timeInMs: 0,
            duration: 4000,
            text: "alpha bravo charlie delta echo",
            words: [
                TimedWord(timeInMs: 0, word: "alpha"),
                TimedWord(timeInMs: 800, word: " bravo"),
                TimedWord(timeInMs: 1600, word: " charlie"),
                TimedWord(timeInMs: 2400, word: " delta"),
                TimedWord(timeInMs: 3200, word: " echo"),
            ]
        )

        let rendered = try Self.render(line: line, at: -500, fontSize: 20, width: 110, height: 120)
        let bands = Self.inkBands(of: rendered)

        // More than one row of ink, and the second row starts flush left.
        #expect(bands.count >= 2)
        let secondRow = try #require(bands.dropFirst().first)
        let firstInk = try #require(secondRow.indices.first { secondRow[$0] > 8 })
        #expect(firstInk <= 5)
    }

    // MARK: - Rendering helpers

    private static func columnAlphas(
        line: SyncedLyricLine,
        at displayTimeMs: Double,
        fontSize: CGFloat,
        width: CGFloat = 320,
        emphasis: Double = 1
    ) throws -> [UInt8] {
        let rendered = try self.render(
            line: line,
            at: displayTimeMs,
            fontSize: fontSize,
            width: width,
            height: 70,
            emphasis: emphasis
        )
        var alphas = [UInt8](repeating: 0, count: rendered.width)
        for x in 0 ..< rendered.width {
            for y in 0 ..< rendered.height {
                alphas[x] = max(alphas[x], rendered.pixels[(y * rendered.width + x) * 4 + 3])
            }
        }
        return alphas
    }

    /// Contiguous vertical runs of scanlines carrying ink, one per rendered row of
    /// text, each reduced to the per-column ink of that row.
    private static func inkBands(of image: RenderedImage) -> [[UInt8]] {
        let rows = (0 ..< image.height).map { y in
            (0 ..< image.width).map { UInt8(image.pixels[(y * image.width + $0) * 4 + 3]) }
        }

        var bands: [[UInt8]] = []
        var current: [UInt8] = []
        for row in rows {
            if row.contains(where: { $0 > 8 }) {
                if current.isEmpty { current = row }
                else { current = zip(current, row).map(max) }
            } else if !current.isEmpty {
                bands.append(current)
                current = []
            }
        }
        if !current.isEmpty { bands.append(current) }
        return bands
    }

    /// Longest run of empty columns between the first and last inked column.
    private static func longestGap(in columns: [UInt8]) -> Int {
        let ink = columns.indices.filter { columns[$0] > 8 }
        guard let first = ink.first, let last = ink.last, last > first else { return 0 }

        var longest = 0
        var current = 0
        for x in first ... last {
            if columns[x] <= 8 {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    /// How far the halo reaches past the last inked column, in pixels.
    private static func haloReach(withGlow: [UInt8], withoutGlow: [UInt8]) -> Int {
        let glyphEnd = withoutGlow.indices.last { withoutGlow[$0] > 3 } ?? 0
        let haloEnd = withGlow.indices.last { withGlow[$0] > 3 } ?? 0
        return haloEnd - glyphEnd
    }

    /// Median alpha of the ink either side of the widest gap inside a row, which is
    /// the space between its words. Medians rather than peaks, because the halo of a
    /// finished word bleeds across the gap and lights up a column or two of the word
    /// after it. Shows whether a row is filled as one unit or as separately timed
    /// words.
    private static func wordSplitMedians(of columns: [UInt8]) -> (left: Int, right: Int) {
        let ink = columns.indices.filter { columns[$0] > 20 }
        guard let first = ink.first, let last = ink.last, last > first else { return (0, 0) }

        var split = (first + last) / 2
        var widest = 0
        var runStart: Int?
        for x in first ... last {
            if columns[x] <= 8 {
                if runStart == nil { runStart = x }
            } else if let start = runStart {
                if x - start > widest {
                    widest = x - start
                    split = start + (x - start) / 2
                }
                runStart = nil
            }
        }

        let left = Self.inkedMedian(of: columns[first ... split])
        guard split < last else { return (left, 0) }
        return (left, Self.inkedMedian(of: columns[(split + 1) ... last]))
    }

    private static func inkedMedian(of columns: ArraySlice<UInt8>) -> Int {
        let ink = columns.filter { $0 > 20 }.sorted()
        guard !ink.isEmpty else { return 0 }
        return Int(ink[ink.count / 2])
    }

    /// Share of the word's inked width that has been filled.
    private static func sungFraction(of columns: [UInt8]) -> Double {
        let ink = columns.indices.filter { columns[$0] > 20 }
        guard let first = ink.first, let last = ink.last, last > first else { return 0 }
        let sung = (first ... last).count { columns[$0] > 170 }
        return Double(sung) / Double(last - first + 1)
    }

    /// The frame a line settles to is the frame it was already showing.
    ///
    /// The highlight moves on, and the row stops drawing, at `settleBoundaryMs` — the same
    /// instant for both — and the departure animation begins on that frame. A settled frame that
    /// looked different would therefore show up as a jump at exactly the wrong moment, in the
    /// middle of the line's scale-down.
    @Test("The settled frame of a finished line is the frame it was already showing")
    func settledFrameIsPixelIdentical() throws {
        let wordTimed = SyncedLyricLine(
            timeInMs: 0,
            duration: 2000,
            text: "aa bb cc",
            words: [
                TimedWord(timeInMs: 0, word: "aa"),
                TimedWord(timeInMs: 700, word: " bb"),
                TimedWord(timeInMs: 1400, word: " cc"),
            ]
        )
        // A line a provider timed only as a whole, and a line with no duration at all.
        let lineSynced = SyncedLyricLine(timeInMs: 0, duration: 2000, text: "aa bb cc", words: nil)

        for line in [wordTimed, lineSynced] {
            let settled = KaraokeFillModel.staticTimeMs(for: .previous, line: line)
            // The last frame the row still draws on the clock, and the exact instant the
            // highlight moves off it.
            let stillLive = KaraokeFillModel.settleBoundaryMs(for: line)

            let settledImage = try Self.render(line: line, at: settled, fontSize: 40, width: 300, height: 120)
            let liveImage = try Self.render(line: line, at: stillLive, fontSize: 40, width: 300, height: 120)

            let worst = zip(settledImage.pixels, liveImage.pixels).map { abs(Int($0) - Int($1)) }.max() ?? 0
            #expect(worst <= 2, "the settled frame differs from the live one by \(worst)/255")
        }
    }

    /// Mean absolute per-channel difference between two frames. The max is useless here
    /// because any glyph edge crossing a pixel saturates it, while the mean reflects how
    /// much of the line actually changed.
    private static func meanChannelDelta(_ a: RenderedImage, _ b: RenderedImage) -> Double {
        let total = zip(a.pixels, b.pixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(a.pixels.count)
    }

    /// Renders one word of a karaoke line on its own, so the emphasis can be driven with the
    /// fill held still.
    private static func renderWord(
        fill: Double,
        swell: Double,
        glow: Double,
        emphasis: Double = 1,
        fontSize: CGFloat = 40
    ) throws -> RenderedImage {
        let text = "MMMM"
        let line = SyncedLyricLine(timeInMs: 0, duration: 1000, text: text, words: [TimedWord(timeInMs: 0, word: text)])
        let width = KaraokeLineLayout(line: line, fontSize: fontSize).textWidths[0]
        let view = KaraokeWordView(
            text: text,
            width: width,
            fill: fill,
            swell: swell,
            glow: glow,
            color: .black,
            dimOpacity: 0.32,
            fontSize: fontSize,
            emphasis: emphasis
        )
        .frame(width: 320, height: 70, alignment: .topLeading)
        // Room above the word for it to lift into, so the test can see the lift rather
        // than a clipped glyph.
        .padding(.top, 30)

        return try Self.draw(view)
    }

    /// The columns (`x`) and rows (`y`) carrying ink.
    private static func inkColumnRange(of image: RenderedImage) -> ClosedRange<Int>? {
        let columns = (0 ..< image.width).filter { x in
            (0 ..< image.height).contains { y in image.pixels[(y * image.width + x) * 4 + 3] > 8 }
        }
        guard let first = columns.first, let last = columns.last else { return nil }
        return first ... last
    }

    private static func inkRowRange(of image: RenderedImage) -> ClosedRange<Int>? {
        let rows = (0 ..< image.height).filter { y in
            (0 ..< image.width).contains { x in image.pixels[(y * image.width + x) * 4 + 3] > 8 }
        }
        guard let first = rows.first, let last = rows.last else { return nil }
        return first ... last
    }

    private struct RenderedImage {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    private static func render(
        line: SyncedLyricLine,
        at displayTimeMs: Double,
        fontSize: CGFloat,
        width: CGFloat,
        height: CGFloat,
        emphasis: Double = 1
    ) throws -> RenderedImage {
        let view = KaraokeLyricsLineView(
            layout: KaraokeLineLayout(line: line, fontSize: fontSize),
            displayTimeMs: displayTimeMs,
            color: .black,
            emphasis: emphasis
        )
        .frame(width: width, height: height, alignment: .topLeading)

        return try Self.draw(view)
    }

    /// Draws a view offscreen and returns its pixels, so a test can inspect what a frame
    /// actually contains.
    private static func draw(_ view: some View) throws -> RenderedImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "ImageRenderer produced no image")

        let pixelCount = image.width * image.height * 4
        var pixels = [UInt8](repeating: 0, count: pixelCount)
        try pixels.withUnsafeMutableBytes { raw in
            let context = try #require(
                CGContext(
                    data: raw.baseAddress,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
            )
        }

        return RenderedImage(width: image.width, height: image.height, pixels: pixels)
    }
}
