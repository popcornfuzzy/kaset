import AppKit
import CoreText
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
    /// Each word split into characters, each with its own slice of that word's fill window.
    /// Derived once, with the layout, so a frame never has to re-derive them.
    let characters: [[KaraokeCharacter]]
    /// Measured advance width of each character, in the same order as `characters`. The
    /// character widths of a word sum to that word's `textWidths` entry.
    let characterWidths: [[CGFloat]]
    /// Whether each word's text reads right-to-left, so a Hebrew or Arabic word is laid out
    /// and fills from its trailing edge.
    let wordDirections: [Bool]
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

        /// The cell each character is drawn in: where the text system puts it, in reading order.
        ///
        /// The distance between consecutive character starts on a `CTLine`. **Not** the difference
        /// between the bounding widths of the text's prefixes, which is the obvious way to get the
        /// same sum and the wrong one: a prefix's bounding width carries the side bearings of its
        /// first and last glyph, so it is not the advance the next glyph is drawn at. The two
        /// disagree by more than a point on ordinary text — `Vava wavy` at 20 pt puts its cells at
        /// 13.77, 23.66, 34.37 … while the glyphs are drawn at 12.52, 23.42, 34.05 … — and that
        /// never mattered while a word was a single text layer.
        ///
        /// It matters as soon as anything is cut out of a word for the lift: a cell has to be where
        /// the word's own text draws that character, or the mask cuts the wrong part of the glyph —
        /// and, when the cut runs as one boundary through the text, every character behind it jumps
        /// by the width of the error each time the edge crosses one.
        func characterWidths(of text: String) -> [CGFloat] {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            var starts = [CGFloat(CTLineGetOffsetForStringIndex(line, 0, nil))]
            var offset = 0
            for character in text {
                offset += String(character).utf16.count
                starts.append(CGFloat(CTLineGetOffsetForStringIndex(line, offset, nil)))
            }
            // `abs` because a right-to-left line measures its characters back from the line's origin;
            // the distance between two neighbouring starts is the cell either way.
            return zip(starts, starts.dropFirst()).map { abs($1 - $0) }
        }

        let words = KaraokeFillModel.words(for: line)
        let space = width(of: " ")
        let characterWidths = words.map { characterWidths(of: $0.text) }
        self.words = words
        // The word's box is the sum of its character cells, so a cell is a rectangle of the word,
        // and of the masks over it, rather than one that runs to the bearings of the word's ends.
        self.textWidths = characterWidths.map { $0.reduce(0, +) }
        self.characterWidths = characterWidths
        self.characters = words.indices.map { index in
            KaraokeFillModel.characters(for: words[index], weightedBy: characterWidths[index])
        }
        self.wordDirections = words.map { $0.text.isRightToLeftText }
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
                KaraokeWordView(
                    word: self.layout.words[index],
                    characters: self.layout.characters[index],
                    characterWidths: self.layout.characterWidths[index],
                    isRightToLeft: self.layout.wordDirections[index],
                    displayTimeMs: self.displayTimeMs,
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

/// One word of a karaoke line: the word's text as a dim base with a bright copy masked to the
/// word's fill edge, a halo blooming behind that edge, and — for the one character the edge is
/// crossing — that character lifted above the text around it.
///
/// The **fill, the mask and the halo are the word's**, exactly as they were when a word was a
/// single text layer: the edge sweeps the word at the word's own pace, and the halo is the blurred
/// image of the whole sung part of the word. The halo was briefly per character and it vanished — a
/// character's slice of a word's window is far shorter than the halo's own 130 ms rise and 170 ms
/// fade, so the bloom never gets going, and all it has to blur is one glyph's half-filled sliver.
///
/// The **emphasis is per character**: the character the edge is crossing is the one that rises, so it
/// has to be drawn apart from the text around it. It is cut out with a **mask**, not drawn as a run of
/// its own. A word used to be drawn as up to three runs, each placed at the cell its first character
/// is drawn in, and that is what made the characters at rest jiggle: a text layer's origin snaps to a
/// whole pixel, so every time the boundary between two runs moved, all the text behind it stepped by a
/// pixel. Masking one text layer leaves every glyph of the word exactly where the word draws it, in
/// every frame: only the mask moves, and only the masked glyph is translated.
///
/// The masks cut on the cells the word's own text draws its characters in
/// (`KaraokeLineLayout.characterWidths`), and the fill mask and the halo are applied over the word as
/// one box. So the edge is continuous across a cut, and nothing on the word moves when the cut does.
@available(macOS 26.0, *)
struct KaraokeWordView: View {
    /// The word: its text, and the window whose fill, mask and halo it is drawn with.
    let word: KaraokeWord
    /// The word's characters, in reading order, each with its own slice of the word's window. The
    /// slice is what the lift is timed by: the character the edge is crossing is the one that rises.
    let characters: [KaraokeCharacter]
    /// Measured advance width of each character, in the same order as `characters`.
    let characterWidths: [CGFloat]
    /// Whether the word reads right-to-left: such a word is laid out, and so fills, from its
    /// trailing edge.
    let isRightToLeft: Bool
    /// Playback position to render at, in milliseconds.
    let displayTimeMs: Double
    var color: Color = .primary
    /// Opacity of the not-yet-sung text.
    var dimOpacity: Double = 0.32
    var fontSize: CGFloat
    /// Strength of the decorative parts: the leading halo and the lift on the character being
    /// sung. `0` renders a plain wipe, which is what Reduce Motion uses.
    var emphasis: Double = 1.0

    /// How far the character being sung rises at the peak of its own envelope, as a fraction of the
    /// font size.
    ///
    /// Deliberately a *fraction* of a pixel at typical text sizes: it is here to keep the character
    /// being sung from being perfectly static, not to be read as movement on its own. The halo is
    /// what marks the edge.
    private static let liftFraction: CGFloat = 0.02

    /// How far a mask is drawn past the top and bottom of the text it cuts.
    ///
    /// A mask is laid out against the view it masks, never measured against the text inside it, and
    /// the character being lifted is drawn above the box it was measured in, so a mask is drawn well
    /// past the text at both ends rather than to the edges of a line box nobody measures.
    private static let maskOverflow: CGFloat = 2000

    /// The width of the word's box: the cells its characters are drawn in, which is the width the
    /// flow layout reserved for it.
    private var width: CGFloat {
        self.characterWidths.reduce(0, +)
    }

    var body: some View {
        let fill = self.word.fill(at: self.displayTimeMs)
        let glow = self.emphasis > 0 ? self.word.glowStrength(at: self.displayTimeMs) : 0
        let lift = self.lift

        ZStack(alignment: .leading) {
            // A fully sung word is drawn once at full brightness: the lit copy covers the dim base
            // exactly, so keeping the base and the mask would only add layers to every frame — and a
            // line mostly shows fully sung words.
            if fill < 1 {
                self.text(isSung: false, lift: lift)
            }

            if fill > 0 {
                if fill >= 1 {
                    // Nothing left to cut, the halo has faded to nothing by the time a word completes,
                    // and the lift has settled with the word: a finished word is one layer.
                    self.text(isSung: true, lift: nil)
                } else {
                    let sung = self.text(isSung: true, lift: lift).mask { self.fillMask(fill) }

                    if glow > 0 {
                        ZStack {
                            // The halo is the *blurred image of the sung layer*, not a blurred copy
                            // sharing its mask: blurring after masking lets it spread past the word's
                            // box the way a bloom does, so it tapers into the line instead of ending
                            // on the edge of the text box.
                            sung
                                .blur(radius: self.fontSize * 0.16)
                                .opacity(0.5 * self.emphasis * glow)
                            sung
                        }
                    } else {
                        sung
                    }
                }
            }
        }
        .frame(width: max(0, self.width), alignment: .leading)
    }

    /// The character the fill edge is crossing and how far it is rising, or `nil` when nothing on the
    /// word is moving — which is when the word is drawn as one layer with no cut in it.
    ///
    /// Internal rather than private so a test can hold the wipe to what its frame budget assumes: at
    /// most one character is ever lifted, and a word at rest is one layer.
    struct Lift: Equatable {
        /// Index of the character the fill edge is crossing, in reading order.
        let index: Int
        /// How far it has risen, 0...1 of `liftFraction` of the font size.
        let amount: Double
    }

    /// The lift this frame draws, taken from the characters' own windows rather than from where the
    /// edge is, so that the wave is timed by the model.
    ///
    /// Exactly at a slice boundary the character before it has just finished (its envelope is zero)
    /// and the one after it has not started, so nothing is lifted for that one frame — and since the
    /// envelope leaves zero with zero slope, the lift is continuous across it.
    ///
    /// `emphasis` scales the lift, so with the decorative parts off (Reduce Motion) nothing moves and
    /// the word stays one layer however far the fill has got.
    var lift: Lift? {
        guard self.emphasis > 0, let moving = self.movingCharacterIndex else { return nil }
        let amount = self.characters[moving].swell(at: self.displayTimeMs) * self.emphasis
        guard amount > 0 else { return nil }
        return Lift(index: moving, amount: amount)
    }

    /// The word's text as **one run, one layer per mask**, drawn in the box the flow layout reserved
    /// for it — with the character being sung cut out of it and drawn again above the rest.
    ///
    /// The whole word is drawn in both halves rather than the runs either side of the cut, because two
    /// runs are two layers at two origins and a text layer's origin snaps to a whole pixel: the text
    /// behind the boundary would step by a pixel every time the boundary moved, which is exactly the
    /// jiggle the mask is here to remove. One run at one origin puts every glyph in the same place on
    /// every frame, and the mask is the only thing that changes.
    @ViewBuilder
    private func text(isSung: Bool, lift: Lift?) -> some View {
        // `fixedSize` so the word takes the width of its own text rather than being truncated to the
        // box it was measured in: that box is the sum of the character cells, which is the width the
        // text draws across to within a fraction of a point, and a text an invisible sub-pixel wider
        // than its box would draw an ellipsis. The frame then *is* the box the cells are measured in,
        // so a cell is one rectangle of the text and of the masks over it alike.
        let layer = Text(self.word.text)
            .foregroundStyle(isSung ? self.color : self.color.opacity(self.dimOpacity))
            .fixedSize()
            .frame(width: max(0, self.width), alignment: .leading)

        if let lift {
            ZStack(alignment: .leading) {
                layer.mask(alignment: .leading) { self.cellRemoved(lift.index) }
                layer
                    .mask(alignment: .leading) { self.cellOnly(lift.index) }
                    // A translation alone: the box the fill mask and the halo are measured against
                    // does not move with the glyph.
                    .offset(y: -self.fontSize * Self.liftFraction * lift.amount)
            }
        } else {
            layer
        }
    }

    /// The word's text with everything but one character's cell cut away.
    private func cellOnly(_ index: Int) -> some View {
        Rectangle()
            .fill(.white)
            .frame(width: max(0, self.width(of: index)), height: 2 * Self.maskOverflow)
            .offset(x: self.cellStart(of: index))
    }

    /// The word's text with one character's cell cut away from it.
    ///
    /// The hole is the same cell as `cellOnly` cuts, so the two halves of the text meet exactly — no
    /// hairline of background splitting the character at the fill edge. The base is drawn and the hole
    /// punched out of it inside one compositing group, so the cut is one drawing operation rather than
    /// two shapes that would each be snapped to the pixel grid on their own.
    private func cellRemoved(_ index: Int) -> some View {
        Rectangle()
            .fill(.white)
            // Leading-aligned, then offset to the cell: an overlay centres a fixed-width child, which
            // would put the hole in the middle of the word however narrow the cell is.
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(.white)
                    .frame(width: max(0, self.width(of: index)), height: 2 * Self.maskOverflow)
                    .offset(x: self.cellStart(of: index))
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
    }

    /// Where a character's cell begins in the word's box, measured from the edge the word's text is
    /// drawn from: a right-to-left word draws its first character at the right of its box, so its cells
    /// count in from the right.
    func cellStart(of index: Int) -> CGFloat {
        guard index > 0 else { return self.isRightToLeft ? self.width - self.width(of: 0) : 0 }
        let pen = self.characterWidths.prefix(index).reduce(0, +)
        return self.isRightToLeft ? self.width - pen - self.width(of: index) : pen
    }

    /// Index of the character the fill edge is crossing: the last character whose slice of the word's
    /// window has opened, and so the one whose lift envelope is the one running.
    private var movingCharacterIndex: Int? {
        self.characters.lastIndex { $0.fill(at: self.displayTimeMs) > 0 }
    }

    private func width(of index: Int) -> CGFloat {
        self.characterWidths.indices.contains(index) ? self.characterWidths[index] : 0
    }

    /// Alpha ramp whose edge sits at the word's fill position and whose feather leads it, over the
    /// word's whole box.
    ///
    /// The edge overshoots the glyphs by the feather, so a fully sung word reaches full brightness
    /// exactly at its end while the halo still leads mid-word. The ramp is clamped to the box, so it
    /// always completes within the mask instead of being cut off at the box edge — a cut ramp is a hard
    /// edge on the halo — and the feather is clamped to half the box for the same reason, which is
    /// what a word too narrow for its own feather gets instead of a hard edge.
    private func fillMask(_ fill: Double) -> some View {
        let boxWidth = max(1, self.width)
        let clamped = min(max(fill, 0), 1)
        let feather = min(self.fontSize * 0.7 * min(1, self.emphasis), boxWidth * 0.5)
        let edge = clamped * (boxWidth + feather)
        let startPx = min(max(edge - feather, 0), boxWidth)
        let endPx = min(max(edge, startPx), boxWidth)
        let points: (UnitPoint, UnitPoint) = self.isRightToLeft ? (.trailing, .leading) : (.leading, .trailing)

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
