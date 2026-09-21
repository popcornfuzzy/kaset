import AppKit
import SwiftUI

// MARK: - KaraokeLineLayout

/// Everything about a line that stays the same for as long as the line is on screen: its
/// words, the measured widths of those words and the font metrics the flow layout needs.
///
/// Text measurement is by far the most expensive thing a karaoke line does, so it happens
/// **once per line** — when the row is built — and never inside the display-clock frame
/// loop. A frame then only does arithmetic on numbers that are already known. `Equatable`
/// is what lets SwiftUI skip a row whose layout has not changed.
@available(macOS 26.0, *)
struct KaraokeLineLayout: Equatable {
    /// The words to draw, each with its own fill window.
    let words: [KaraokeWord]
    /// Measured advance width of each word's text.
    let textWidths: [CGFloat]
    /// Gap to leave before each word: a space at a word boundary, nothing between the
    /// syllables of one word, and nothing before the first word of a row.
    let gaps: [CGFloat]
    /// Height of one row of text.
    let lineHeight: CGFloat
    let fontSize: CGFloat
    let weight: Font.Weight
    /// Whether the provider timed the line only as a whole. Such a line is drawn as one
    /// unit and never split into words we would have to invent timings for.
    let isLineSynced: Bool

    init(line: SyncedLyricLine, fontSize: CGFloat, weight: Font.Weight = .bold) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: Self.nsWeight(for: weight))
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        func width(of text: String) -> CGFloat {
            (text as NSString).size(withAttributes: attributes).width
        }

        let words = KaraokeFillModel.words(for: line)
        let space = width(of: " ")
        self.words = words
        self.textWidths = words.map { width(of: $0.text) }
        self.gaps = words.indices.map { index in
            index > 0 && words[index].isNewWord ? space : 0
        }
        self.lineHeight = font.ascender - font.descender + font.leading
        self.fontSize = fontSize
        self.weight = weight
        self.isLineSynced = (line.words ?? []).isEmpty
    }

    private static func nsWeight(for weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}

// MARK: - KaraokeLayoutCache

/// Memoizes the measured layout of each lyric line.
///
/// Measuring a line is the expensive part of drawing it, and a row's body is re-evaluated
/// whenever the lyric sheet re-renders — a row carries a tap closure, and a view with a
/// closure is never considered unchanged. The cache keeps that re-render at a dictionary
/// lookup, and hands every frame of a line the same `Equatable` layout, which is what lets
/// SwiftUI skip the row's drawing entirely while the line is settled.
@available(macOS 26.0, *)
@MainActor
final class KaraokeLayoutCache {
    private var layouts: [UUID: KaraokeLineLayout] = [:]
    private var fontSize: CGFloat = 0

    func layout(for line: SyncedLyricLine, fontSize: CGFloat) -> KaraokeLineLayout {
        if self.fontSize != fontSize {
            self.layouts.removeAll(keepingCapacity: true)
            self.fontSize = fontSize
        }
        // Bound the cache: a lyric sheet is a few hundred lines at most, and the words and
        // widths a layout holds are tiny, but a session plays many tracks.
        if self.layouts.count > 512 { self.layouts.removeAll(keepingCapacity: true) }
        if let cached = self.layouts[line.id] { return cached }

        let layout = KaraokeLineLayout(line: line, fontSize: fontSize)
        self.layouts[line.id] = layout
        return layout
    }
}

// MARK: - KaraokeLyricsLineView

/// Renders one timed lyric line as an Apple Music-style karaoke wipe: the sung part
/// of every word fills with a soft, glowing leading edge while the rest of the line
/// stays dimmed.
///
/// Pass the live display clock's position for the line being sung. For every other
/// line pass `KaraokeFillModel.staticTimeMs(for:line:)` — finished lines then read as
/// fully sung and upcoming lines as untouched, which keeps per-frame work confined
/// to the one line that is actually moving.
///
/// The line's layout (`KaraokeLineLayout`) is built once by the row and passed in, so
/// neither measuring text nor deriving the word timings happens per frame.
@available(macOS 26.0, *)
struct KaraokeLyricsLineView: View {
    let layout: KaraokeLineLayout
    /// Playback position to render at, in milliseconds.
    let displayTimeMs: Double
    var color: Color = .primary
    /// Opacity of the not-yet-sung text.
    var dimOpacity: Double = 0.32
    /// Strength of the decorative parts: the leading glow and the lift on the word
    /// being sung. `0` renders a plain wipe, which is what Reduce Motion uses.
    var emphasis: Double = 1.0
    var lineSpacing: CGFloat = 2

    @Environment(\.layoutDirection) private var layoutDirection

    @ViewBuilder
    var body: some View {
        if self.layout.isLineSynced {
            self.lineSyncedText
        } else {
            self.wordTimedText
        }
    }

    /// Line-synced lyrics, sung as a line: the line appears at its own start and then
    /// stays fully lit for the whole time it is being sung, with no invented word
    /// boundaries and no gradual brightening across the line.
    private var lineSyncedText: some View {
        let word = self.layout.words.first
        let appear = word?.appearProgress(at: self.displayTimeMs) ?? 0
        let halo = word?.haloStrength(at: self.displayTimeMs) ?? 0

        return ZStack(alignment: .leading) {
            Text(self.layout.words.first?.text ?? "")
                .foregroundStyle(self.color.opacity(self.dimOpacity))

            if appear > 0 {
                let lit = Text(self.layout.words.first?.text ?? "")
                    .foregroundStyle(self.color)
                    .opacity(appear)

                if self.emphasis > 0, halo > 0 {
                    lit
                        .blur(radius: self.layout.fontSize * 0.16)
                        .opacity(0.5 * self.emphasis * halo)
                }

                lit
            }
        }
        .font(.system(size: self.layout.fontSize, weight: self.layout.weight))
        .lineSpacing(self.lineSpacing)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var wordTimedText: some View {
        KaraokeWordFlowLayout(
            widths: self.layout.textWidths,
            gaps: self.layout.gaps,
            lineHeight: self.layout.lineHeight,
            lineSpacing: self.lineSpacing,
            isRightToLeft: self.layoutDirection == .rightToLeft
        ) {
            ForEach(self.layout.words.indices, id: \.self) { index in
                let word = self.layout.words[index]
                KaraokeWordView(
                    text: word.text,
                    width: self.layout.textWidths[index],
                    fill: word.fill(at: self.displayTimeMs),
                    swell: word.swell(at: self.displayTimeMs),
                    color: self.color,
                    dimOpacity: self.dimOpacity,
                    fontSize: self.layout.fontSize,
                    emphasis: self.emphasis
                )
            }
        }
        .font(.system(size: self.layout.fontSize, weight: self.layout.weight))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - KaraokeWordView

/// One word of a karaoke line: dim text with a brighter copy masked to the filled
/// span, plus an optional glow and lift while the word is being sung.
@available(macOS 26.0, *)
struct KaraokeWordView: View {
    let text: String
    /// Measured width of the word's text, so the fill mask needs no layout geometry
    /// (and no `GeometryReader` in the frame loop).
    let width: CGFloat
    /// How much of the word has been sung, 0...1.
    let fill: Double
    /// How much this word is emphasised, 0...1, from the model's time-based
    /// envelope: it cannot pop because it is never read part-way through.
    let swell: Double
    let color: Color
    let dimOpacity: Double
    let fontSize: CGFloat
    let emphasis: Double

    /// Distance ahead of the fill edge over which colour ramps in. A fixed distance
    /// rather than a fraction of the word, so short and long words carry the same
    /// halo instead of the halo growing with the word.
    private var featherPx: CGFloat {
        guard self.emphasis > 0 else { return 0 }
        return self.fontSize * 0.7 * min(1, self.emphasis)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // A fully sung word is drawn once at full brightness: the lit copy covers the
            // dim base exactly, so keeping the base and the mask would only add a layer
            // each to every frame — and a line mostly shows fully sung words.
            if self.fill < 1 {
                Text(self.text)
                    .foregroundStyle(self.color.opacity(self.dimOpacity))
            }

            if self.fill > 0 {
                self.sungLayer
            }
        }
        .scaleEffect(1 + 0.032 * self.emphasis * self.swell)
        .offset(y: -self.fontSize * 0.018 * self.emphasis * self.swell)
    }

    /// The sung part of the word and the halo it casts.
    ///
    /// The halo is the *blurred image of the sung layer*, not a blurred copy sharing
    /// the same mask: blurring after masking lets it spread past the word's box the
    /// way a bloom does, so the glow tapers into the line instead of ending on the
    /// edge of the text box.
    @ViewBuilder
    private var sungLayer: some View {
        let lit = Text(self.text).foregroundStyle(self.color)

        if self.fill >= 1 {
            // Fully sung: there is nothing left to mask and no edge left to glow, so the
            // word costs a single text layer instead of three.
            lit
        } else {
            let sung = lit.mask { self.fillMask }

            if self.emphasis > 0 {
                ZStack {
                    sung
                        .blur(radius: self.fontSize * 0.16)
                        .opacity(0.5 * self.emphasis * self.glowFade)
                    sung
                }
            } else {
                sung
            }
        }
    }

    /// The halo eases in with the word instead of snapping on at its first pixel.
    private var glowFade: Double {
        min(1, max(self.fill, 0) * 3)
    }

    /// Alpha ramp whose edge sits at the word's fill position and whose feather leads
    /// it. The edge overshoots the glyphs by the feather, so a fully sung word reaches
    /// full brightness exactly at its end while the halo still leads mid-word.
    ///
    /// The ramp is clamped to the word's box, so it always completes within the mask
    /// instead of being cut off at the box edge — a cut ramp is a hard edge on the halo.
    private var fillMask: some View {
        let boxWidth = max(1, self.width)
        let fill = min(max(self.fill, 0), 1)
        let feather = min(self.featherPx, boxWidth * 0.5)
        let edge = fill * (boxWidth + feather)
        let startPx = min(max(edge - feather, 0), boxWidth)
        let endPx = min(max(edge, startPx), boxWidth)
        let points: (UnitPoint, UnitPoint) = self.text.isRightToLeftText ? (.trailing, .leading) : (.leading, .trailing)

        return Rectangle().fill(
            LinearGradient(
                stops: [
                    .init(color: .white, location: startPx / boxWidth),
                    .init(color: .white.opacity(0), location: endPx / boxWidth),
                ],
                startPoint: points.0,
                endPoint: points.1
            )
        )
    }
}

private extension String {
    /// Whether the text's first strongly-directional character reads right-to-left.
    /// Those words fill from their trailing edge, so a Hebrew or Arabic word inside
    /// a left-to-right line still fills the way it reads.
    var isRightToLeftText: Bool {
        for scalar in self.unicodeScalars {
            switch scalar.value {
            case 0x41 ... 0x5A, 0x61 ... 0x7A, 0xC0 ... 0x2AF, 0x370 ... 0x58F:
                return false
            case 0x590 ... 0x5FF, 0x600 ... 0x8FF, 0xFB1D ... 0xFDFF, 0xFE70 ... 0xFEFF, 0x1EE00 ... 0x1EEFF:
                return true
            default:
                continue
            }
        }
        return false
    }
}

// MARK: - KaraokeWordFlowLayout

/// Wraps karaoke words at the container width, keeping every word its own view so
/// each can carry its own fill mask.
///
/// Greedy first-fit wrapping mirrors what `Text` does with the same words as one
/// string, which is what the line was before it was split apart for per-word masks.
/// The words' widths are handed to the layout rather than measured by it, so a frame
/// costs arithmetic and nothing else.
@available(macOS 26.0, *)
struct KaraokeWordFlowLayout: Layout {
    /// Measured width of each word, in the same order as the subviews.
    let widths: [CGFloat]
    /// Gap each word asks for before itself, in the same order as the subviews.
    let gaps: [CGFloat]
    /// Height of one row of text.
    var lineHeight: CGFloat
    var lineSpacing: CGFloat = 0
    /// Right-to-left lyrics wrap and fill from the trailing edge.
    var isRightToLeft: Bool = false

    func sizeThatFits(proposal: ProposedViewSize, subviews _: Subviews, cache _: inout ()) -> CGSize {
        let rows = self.rows(fitting: proposal.width ?? .infinity)
        return CGSize(
            width: proposal.width ?? (rows.map(\.width).max() ?? 0),
            height: CGFloat(rows.count) * self.lineHeight
                + CGFloat(max(0, rows.count - 1)) * self.lineSpacing
        )
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var top = bounds.minY

        for row in self.rows(fitting: bounds.width) {
            var pen = self.isRightToLeft ? bounds.maxX : bounds.minX
            for (position, index) in row.indices.enumerated() {
                guard subviews.indices.contains(index) else { continue }
                // A wrapped row starts at the margin: the gap a word asks for only
                // applies between words, never as indentation.
                if position > 0 {
                    let gap = self.gaps[index]
                    pen += self.isRightToLeft ? -gap : gap
                }
                let width = self.widths[index]
                subviews[index].place(
                    at: CGPoint(x: self.isRightToLeft ? pen - width : pen, y: top),
                    anchor: .topLeading,
                    proposal: .unspecified
                )
                pen += self.isRightToLeft ? -width : width
            }
            top += self.lineHeight + self.lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
    }

    private func rows(fitting maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in self.widths.indices {
            let needed = current.indices.isEmpty
                ? self.widths[index]
                : self.gaps[index] + self.widths[index]
            if !current.indices.isEmpty, current.width + needed > maxWidth {
                rows.append(current)
                current = Row()
            }

            current.width += current.indices.isEmpty ? self.widths[index] : needed
            current.indices.append(index)
        }

        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
