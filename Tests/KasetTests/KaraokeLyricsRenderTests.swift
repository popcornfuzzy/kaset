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

    /// The halo is the word's, and it blooms past the word's box instead of being cut off at it.
    ///
    /// This is also what catches a halo that is not there at all, which is what a per-character halo
    /// amounts to: a character's slice of a word's window is a fraction of the 130 ms its own bloom
    /// takes to rise, so the glow never gets going, and the only ink it has to blur is one glyph's
    /// half-filled sliver.
    @Test("The halo blooms past the word's box instead of being cut off at it")
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

    /// The emphasis on the character being sung must not resize its text.
    ///
    /// A scale is the obvious way to express "this character is lifting", and it is the wrong one:
    /// SwiftUI re-rasterizes scaled text on every frame, so a scaled character steps and then snaps as
    /// it settles. The lift is a translation, so the glyph keeps its raster: the character's own ink is
    /// the same height with the emphasis on as with it off, and only sits higher.
    ///
    /// The character's *own* cell is what is measured, at the alpha a lit glyph reaches and a halo does
    /// not — the fill mask cuts the glyph in different places with the emphasis on (a feathered edge)
    /// and off (a hard one), so the word's ink as a whole is not comparable between the two.
    @Test("The character being sung lifts instead of resizing")
    func emphasisLiftsRatherThanScales() throws {
        let line = SyncedLyricLine(
            timeInMs: 0,
            duration: 1200,
            text: "MMMM",
            words: [TimedWord(timeInMs: 0, word: "MMMM")]
        )
        let layout = KaraokeLineLayout(line: line, fontSize: 100)
        let characters = try #require(layout.characters.first)
        // The peak of the second character's own swell: it is the character the fill edge is crossing,
        // and it is at full lift there.
        let peak = (characters[1].fillStartMs + characters[1].fillEndMs) / 2
        let cell = Self.cell(1, of: layout)

        let raised = try #require(Self.litRows(try Self.renderWord(line: line, at: peak, fontSize: 100), columns: cell))
        let resting = try #require(Self.litRows(try Self.renderWord(line: line, at: peak, fontSize: 100, emphasis: 0), columns: cell))

        // A scale would show up as a taller glyph; a translation leaves the ink the same height.
        #expect(abs(raised.count - resting.count) <= 1, "the emphasis resized the character (\(raised.count) rows against \(resting.count))")

        // And the lift does move it, so the emphasis is still doing something.
        let raisedTop = try #require(raised.first)
        let restingTop = try #require(resting.first)
        #expect(raisedTop < restingTop, "the character being sung did not rise")
    }

    /// The lift is a wave that travels through a word, not one translation of the whole word.
    ///
    /// Each character owns a slice of its word's fill window, so the character the fill edge is
    /// crossing is the one the emphasis is on: it rises while the characters behind and ahead of it
    /// stay at rest. Nothing offscreen can see the emphasis move through a row, so this follows the
    /// pixels instead — the six characters are the same glyph, which makes the top row of a band the
    /// only thing that can differ, and the lifted band is the one that sits higher.
    ///
    /// A band's top row is read at the alpha a fully lit glyph reaches and a halo does not: at this
    /// font size the halo around the character being sung blurs further than a band is inset, so its
    /// faint ink would otherwise be what the neighbouring band found.
    @Test("The lift travels across a word one character at a time")
    func liftTravelsAcrossTheWord() throws {
        let text = "MMMMMM"
        let line = SyncedLyricLine(
            timeInMs: 0,
            duration: 1200,
            text: text,
            words: [TimedWord(timeInMs: 0, word: text)]
        )
        let layout = KaraokeLineLayout(line: line, fontSize: 100)
        let characters = try #require(layout.characters.first)
        #expect(characters.count == 6)

        /// The top of each character's glyph at the peak of one character's own swell — the moment
        /// the emphasis is on that character, with the ones before it already settled (their windows
        /// have closed by then) and the ones after it not yet moving.
        func glyphTops(moving index: Int) throws -> [Int?] {
            let peak = (characters[index].fillStartMs + characters[index].fillEndMs) / 2
            #expect(characters[index].swell(at: peak) > 0.9, "the character under the edge was not at its peak")
            #expect(characters[index - 1].swell(at: peak) == 0, "the character before the edge was still moving")

            let view = KaraokeWordView(
                word: layout.words[0],
                characters: characters,
                characterWidths: layout.characterWidths[0],
                isRightToLeft: false,
                displayTimeMs: peak,
                color: .black,
                fontSize: layout.fontSize
            )
            // The font the row draws with, applied the way the line view applies it: the character
            // widths are measured in this font, so a band of columns is one character's own slot.
            .font(.system(size: layout.fontSize, weight: .bold))
            .frame(width: 800, height: 200, alignment: .topLeading)
            // Room above the row for a character to rise into, so the test measures a lifted glyph
            // rather than a clipped one.
            .padding(.top, 40)
            let rendered = try Self.draw(view)

            var pen: CGFloat = 0
            return layout.characterWidths[0].map { width in
                let start = Int(pen) + 4
                pen += width
                return Self.topInkRow(
                    of: rendered,
                    columns: start ..< max(start + 1, Int(pen) - 4),
                    above: Self.litAlpha
                )
            }
        }

        // With the third character under the edge, the first two are fully sung: two characters at
        // rest are level, and the one being sung sits above them.
        let thirdMoving = try glyphTops(moving: 3)
        let atRest = try #require(thirdMoving[1])
        #expect(thirdMoving[2] == atRest, "two characters at rest did not sit level")
        let raised = try #require(thirdMoving[3], "the character being sung was not lit")
        #expect(atRest - raised >= 1, "the lift was under a pixel at \(layout.fontSize)pt")

        // And the characters the edge has not reached are dim rather than lit, so the only bands
        // that can be lifted are the ones behind and under the edge.
        #expect(thirdMoving[4] == nil, "a character the fill had not reached was drawn fully lit")

        // The same character, one frame with the edge on it and one with the edge already past it:
        // the wave has moved on, which a single translation of the whole word could never do.
        let firstMoving = try glyphTops(moving: 1)
        let wasLifted = try #require(firstMoving[1])
        #expect(wasLifted < atRest, "the character the edge had left was still lifted")
    }

    /// A word's character cells are where the text draws its characters.
    ///
    /// This pins the regression that made every character behind the fill edge twitch each time the
    /// edge crossed one. The cells used to be the differences between the *bounding* widths of the
    /// text's prefixes, and a bounding width carries the side bearings of its first and last glyph, so
    /// those differences are not the advances the drawn text uses: `Vava wavy` at 20 pt puts its cells
    /// at 13.77, 23.66, 34.37 … while its glyphs are drawn at 12.52, 23.42, 34.05 … A word is drawn in
    /// pieces for the lift now, on these cells, so a cell that is not where the glyph is means a piece
    /// boundary that drags the text behind it.
    @Test("A word's character cells are where the text draws its characters")
    func characterCellsAreWhereTheTextDraws() throws {
        for text in ["Vava wavy", "MMMMMM", "To together", "Aa"] {
            let line = SyncedLyricLine(
                timeInMs: 0,
                duration: 1000,
                text: text,
                words: [TimedWord(timeInMs: 0, word: text)]
            )
            let layout = KaraokeLineLayout(line: line, fontSize: 20)
            let characters = try #require(layout.characters.first)
            let drawn = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: text,
                    attributes: [.font: NSFont.systemFont(ofSize: 20, weight: .bold)]
                )
            )

            var pen: CGFloat = 0
            var offset = 0
            for (index, character) in characters.enumerated() {
                let start = CGFloat(CTLineGetOffsetForStringIndex(drawn, offset, nil))
                #expect(abs(pen - start) < 0.05, "cell \(index) of `\(text)` sits at \(pen); the glyph is drawn at \(start)")
                pen += layout.characterWidths[0][index]
                offset += character.text.utf16.count
            }

            // And the cells add up to the width the word is drawn across, which is the width the flow
            // layout reserved for it.
            let advance = CGFloat(CTLineGetTypographicBounds(drawn, nil, nil, nil))
            #expect(abs(pen - advance) < 0.05, "the cells of `\(text)` span \(pen) of \(advance)")
            #expect(abs(layout.textWidths[0] - advance) < 0.05, "the word's box is \(layout.textWidths[0]) of \(advance)")
        }
    }

    /// Only the character the fill edge is crossing moves.
    ///
    /// A character behind the edge has been sung and one ahead of it has not been reached: neither may
    /// take a different shape while the wave crosses the word, which is what the cells and the pieces
    /// are arranged to guarantee. Read at 100 pt, where a lift is several pixels, so a stray half-pixel
    /// is not what is being measured.
    ///
    /// The characters just behind the edge are left out: the fill's leading edge is a feathered ramp
    /// almost a cell wide, so the two characters nearest it are still being lit up. The sung
    /// characters that *are* read are read at the alpha a lit glyph reaches and a halo does not, and the
    /// unsung ones are read two cells clear of the halo the edge casts.
    @Test("The characters at rest do not move while the fill edge crosses the word")
    func theWaveMovesNothingElse() throws {
        let text = "MMMMMMMMMM"
        let line = SyncedLyricLine(
            timeInMs: 0,
            duration: 1200,
            text: text,
            words: [TimedWord(timeInMs: 0, word: text)]
        )
        let layout = KaraokeLineLayout(line: line, fontSize: 100)
        let characters = try #require(layout.characters.first)
        let cells = characters.indices.map { Self.cell($0, of: layout) }

        var sung = [[Double]](repeating: [], count: characters.count)
        var unsung = [[Double]](repeating: [], count: characters.count)

        for step in stride(from: -200.0, through: 1500.0, by: 20) {
            let rendered = try Self.renderWord(line: line, at: step, fontSize: 100, width: 1200)
            let moving = characters.lastIndex { $0.fill(at: step) > 0 }

            /// Where a cell's ink sits, in columns: its alpha-weighted centre. A character that has moved
            /// has a centre that has moved — the drift this pins is over a point at 20 pt and several at
            /// 100 pt — while a faint halo lying over it leaves the centre where it was. The halo over a
            /// sung character is the blurred image of the whole sung part of the word, so it is there in
            /// every frame, and a threshold on its own would read the halo rather than the glyph.
            func centre(of cell: Range<Int>, above: UInt8) -> Double? {
                let cell = cell.clamped(to: 0 ..< rendered.width)
                var total = 0.0
                var weighted = 0.0
                for x in cell {
                    let peak = (0 ..< rendered.height)
                        .map { y in Double(rendered.pixels[(y * rendered.width + x) * 4 + 3]) }
                        .max() ?? 0
                    guard peak > Double(above) else { continue }
                    total += peak
                    weighted += Double(x) * peak
                }
                return total > 0 ? weighted / total : nil
            }

            for index in characters.indices {
                if characters[index].fill(at: step) >= 1, let moving, index <= moving - 3,
                   let centre = centre(of: cells[index], above: Self.litAlpha)
                {
                    sung[index].append(centre)
                }
                if characters[index].fill(at: step) == 0, let moving, index >= moving + 2,
                   let centre = centre(of: cells[index], above: 8)
                {
                    unsung[index].append(centre)
                }
            }
        }

        for index in characters.indices {
            for (kind, centres) in [("sung", sung[index]), ("unsung", unsung[index])] {
                guard let first = centres.first else { continue }
                let moved = centres.map { abs($0 - first) }.max() ?? 0
                #expect(moved < 0.5, "the \(kind) character at \(index) moved \(moved.formatted(.number.precision(.fractionLength(2)))) columns while the edge crossed the word")
            }
        }
    }

    /// Alpha a fully lit glyph reaches and the halo around one does not: the halo is drawn at half
    /// opacity and blurred, so its ink is faint even where it is densest, while a lit glyph's core is
    /// opaque. Reading a band at this threshold reads glyphs rather than glows.
    private static let litAlpha: UInt8 = 170

    /// One character moves at a time, and a word nothing is happening to is one layer.
    ///
    /// The structural half of the frame budget (`KaraokeLyricsPerformanceTests` prices it): the lift is
    /// timed per character now, so "a settled word is one layer" is a property the code has to be held
    /// to rather than one it can be trusted to keep by accident. A row is mostly settled words, and it is
    /// those that set what a frame costs. A lift is `nil` exactly when nothing is moving, which is when
    /// the word is drawn as one layer with no mask over it.
    @Test("A word lifts one character at a time, and is one layer at rest")
    func theLiftMovesOneCharacterAtATime() throws {
        let line = SyncedLyricLine(
            timeInMs: 0,
            duration: 1200,
            text: "MMM MM",
            words: [TimedWord(timeInMs: 0, word: "MMM"), TimedWord(timeInMs: 600, word: " MM")]
        )
        let layout = KaraokeLineLayout(line: line, fontSize: 16)
        #expect(layout.words.count == 2)

        for index in layout.words.indices {
            var liftedInOrder: [Int] = []
            var atRest = 0

            for step in stride(from: -400, through: 1800, by: 10) {
                let word = KaraokeWordView(
                    word: layout.words[index],
                    characters: layout.characters[index],
                    characterWidths: layout.characterWidths[index],
                    isRightToLeft: false,
                    displayTimeMs: Double(step),
                    fontSize: layout.fontSize
                )

                guard let lift = word.lift else {
                    atRest += 1
                    continue
                }

                // One character, and only ever one, at a lift the font size can make room for.
                #expect(lift.amount > 0 && lift.amount <= 1, "the lift was \(lift.amount) at \(step)ms")
                // And it is a cell of this word: the mask can only cut a word where the word is drawn.
                let start = word.cellStart(of: lift.index)
                #expect(start >= -0.01, "the lifted cell of `\(layout.words[index].text)` started at \(start)")
                #expect(
                    start + layout.characterWidths[index][lift.index] <= layout.textWidths[index] + 0.01,
                    "the lifted cell of `\(layout.words[index].text)` ran past its box"
                )

                if liftedInOrder.last != lift.index { liftedInOrder.append(lift.index) }
            }

            // Before the fill arrives and after the word has settled, the word is one layer.
            #expect(atRest > 0)
            // The wave crosses the word one character at a time, in reading order, and touches every
            // character of it.
            #expect(liftedInOrder == liftedInOrder.sorted(), "the wave went backwards through `\(layout.words[index].text)`")
            #expect(Set(liftedInOrder) == Set(layout.characters[index].indices), "the wave skipped a character of `\(layout.words[index].text)`")
        }
    }

    /// The two halves of the cut word cover it exactly: what the lift takes out of the word is drawn
    /// again above it, and nothing is left behind.
    ///
    /// A mask placed against the wrong part of the word takes ink away with it, and the word loses a band
    /// of itself on every frame the wave is on it — a hole the width of a character, which is what a mask
    /// left centred instead of led to its cell does. Read with the dim base opaque, so the word's ink is
    /// as bright as it gets and the only thing that can change it is the cut: the character being lifted
    /// is the same glyph moved up by a pixel.
    @Test("Cutting the word for the lift takes nothing out of it")
    func theCutTakesNothingOutOfTheWord() throws {
        let text = "MMMMMM"
        let line = SyncedLyricLine(
            timeInMs: 0,
            duration: 1200,
            text: text,
            words: [TimedWord(timeInMs: 0, word: text)]
        )
        let layout = KaraokeLineLayout(line: line, fontSize: 60)
        let characters = try #require(layout.characters.first)

        for index in 1 ..< characters.count - 1 {
            // Each character's own peak: the wave is on it, and the ones around it are at rest.
            let peak = (characters[index].fillStartMs + characters[index].fillEndMs) / 2
            let cut = try Self.columnAlphas(of: Self.renderWord(line: line, at: peak, fontSize: 60, dimOpacity: 1))
            let whole = try Self.columnAlphas(of: Self.renderWord(line: line, at: peak, fontSize: 60, emphasis: 0, dimOpacity: 1))

            let cutInk = cut.reduce(0) { $0 + Int($1) }
            let wholeInk = whole.reduce(0) { $0 + Int($1) }
            #expect(
                abs(cutInk - wholeInk) < wholeInk / 20,
                "the cut took \(wholeInk - cutInk) of the word's \(wholeInk) ink at \(index)"
            )

            // And no band of the word goes missing: the widest gap in the cut word is a gap the word
            // itself has.
            #expect(
                Self.longestGap(in: cut) <= Self.longestGap(in: whole) + 2,
                "the cut left a gap of \(Self.longestGap(in: cut)) columns in the word at \(index)"
            )

            // No column of the word loses its ink either. The two halves of the cut have to meet: a
            // half a pixel apart leaves a hairline of background through the word, which is invisible
            // where the cut falls on the gap between two glyphs and is a bright stripe through a
            // character where it does not.
            for x in 1 ..< min(cut.count, whole.count) - 1 where whole[x - 1] > 200 && whole[x + 1] > 200 {
                #expect(cut[x] > 120, "the cut left a hairline at column \(x) of the word at \(index)")
            }
        }
    }

    /// A right-to-left word is still drawn from the edge it is read from.
    ///
    /// A word's cells are measured in reading order and drawn from the edge the word is read from, so an
    /// RTL word's first character is at the *right* of its box and the wave crosses it right to left.
    /// Cutting a word into cells for the lift must not quietly turn that around: a Hebrew or Arabic word
    /// cut left-to-right is a word whose character lifts somewhere the fill edge is not.
    @Test("A right-to-left word draws its cells from its trailing edge")
    func rightToLeftWordDrawsTrailingFirst() throws {
        let text = "אבג"
        let line = SyncedLyricLine(
            timeInMs: 0,
            duration: 1200,
            text: text,
            words: [TimedWord(timeInMs: 0, word: text)]
        )
        let layout = KaraokeLineLayout(line: line, fontSize: 40)
        let characters = try #require(layout.characters.first)
        let widths = layout.characterWidths[0]
        let box = layout.textWidths[0]
        #expect(characters.map(\.text) == ["א", "ב", "ג"])

        func word(isRightToLeft: Bool) -> KaraokeWordView {
            KaraokeWordView(
                word: layout.words[0],
                characters: characters,
                characterWidths: widths,
                isRightToLeft: isRightToLeft,
                displayTimeMs: 0,
                color: .black,
                fontSize: layout.fontSize
            )
        }

        let leftToRight = word(isRightToLeft: false)
        let rightToLeft = word(isRightToLeft: true)

        // The character read first starts the box left to right and ends it right to left...
        #expect(abs(leftToRight.cellStart(of: 0)) < 0.01)
        #expect(abs(rightToLeft.cellStart(of: 0) - (box - widths[0])) < 0.01)

        // ...and the one read last ends it the other way round. The two are the same cells, mirrored.
        #expect(abs(leftToRight.cellStart(of: 2) - (widths[0] + widths[1])) < 0.01)
        #expect(abs(rightToLeft.cellStart(of: 2)) < 0.01)

        // So the lift is on the same character either way, and it is the character the fill edge is
        // crossing when that is the middle one of the word.
        for index in characters.indices {
            let peak = (characters[index].fillStartMs + characters[index].fillEndMs) / 2
            let lifted = KaraokeWordView(
                word: layout.words[0],
                characters: characters,
                characterWidths: widths,
                isRightToLeft: true,
                displayTimeMs: peak,
                color: .black,
                fontSize: layout.fontSize
            ).lift
            #expect(lifted?.index == index, "the wave was on character \(String(describing: lifted?.index)) of the edge over \(index)")
        }
    }

    /// A right-to-left word fills from its trailing edge, and is read the other way round only in how its
    /// characters are ordered inside the box.
    @Test("A right-to-left word fills from its trailing edge")
    func rightToLeftWordFillsFromItsTrailingEdge() throws {
        let text = "אבג"
        let line = SyncedLyricLine(
            timeInMs: 0,
            duration: 1000,
            text: text,
            words: [TimedWord(timeInMs: 0, word: text)]
        )

        /// Mean alpha of the inked columns in each half of the word's ink, which is which side of the word
        /// the fill has reached.
        func halves(_ columns: [UInt8]) -> (leading: Int, trailing: Int) {
            let ink = columns.indices.filter { columns[$0] > 20 }
            guard let first = ink.first, let last = ink.last, last > first else { return (0, 0) }
            let middle = (first + last) / 2
            func mean(_ range: ClosedRange<Int>) -> Int {
                let values = range.map { Int(columns[$0]) }
                return values.reduce(0, +) / max(1, values.count)
            }
            return (mean(first ... middle), mean((middle + 1) ... last))
        }

        // Half way through the word: the half the word is read from is the half that has been sung.
        let rightToLeft = halves(Self.columnAlphas(of: try Self.renderWord(line: line, at: 500, fontSize: 60, isRightToLeft: true)))
        let leftToRight = halves(Self.columnAlphas(of: try Self.renderWord(line: line, at: 500, fontSize: 60, isRightToLeft: false)))

        #expect(rightToLeft.trailing > rightToLeft.leading + 40, "a right-to-left word filled towards its leading edge")
        #expect(leftToRight.leading > leftToRight.trailing + 40, "a left-to-right word filled towards its trailing edge")
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

    /// Renders the first word of a line on its own, in the font the row draws it with, at a playback
    /// position — so a word's layers can be driven by the clock while the rest of the line is left out.
    private static func renderWord(
        line: SyncedLyricLine,
        at displayTimeMs: Double,
        fontSize: CGFloat,
        emphasis: Double = 1,
        isRightToLeft: Bool = false,
        dimOpacity: Double = 0.32,
        width: CGFloat = 800
    ) throws -> RenderedImage {
        let layout = KaraokeLineLayout(line: line, fontSize: fontSize)
        let view = KaraokeWordView(
            word: layout.words[0],
            characters: try #require(layout.characters.first),
            characterWidths: try #require(layout.characterWidths.first),
            isRightToLeft: isRightToLeft,
            displayTimeMs: displayTimeMs,
            color: .black,
            dimOpacity: dimOpacity,
            fontSize: fontSize,
            emphasis: emphasis
        )
        // The font the row draws with, applied the way the line view applies it: the character cells
        // are measured in this font, so a cell of columns is one character's own slot.
        .font(.system(size: fontSize, weight: .bold))
        .frame(width: width, height: 220, alignment: .topLeading)
        // Room above the word for a character to lift into, so a test sees a lifted glyph rather than
        // a clipped one.
        .padding(.top, 40)

        return try Self.draw(view)
    }

    /// The columns one character of a word is drawn in, inset so that a neighbouring glyph's overhang
    /// or the ink the halo spreads into the neighbouring cell cannot be read as part of it.
    private static func cell(_ index: Int, of layout: KaraokeLineLayout) -> Range<Int> {
        var pen: CGFloat = 0
        for width in layout.characterWidths[0].prefix(index) { pen += width }
        let start = Int(pen) + 2
        let end = Int(pen + layout.characterWidths[0][index]) - 2
        return start ..< max(start + 1, end)
    }

    /// The rows of lit ink inside a range of columns: the alpha a fully lit glyph reaches and a halo
    /// does not, so a glow is never what is measured.
    private static func litRows(_ image: RenderedImage, columns: Range<Int>) -> [Int]? {
        let columns = columns.clamped(to: 0 ..< image.width)
        let rows = (0 ..< image.height).filter { y in
            columns.contains { x in image.pixels[(y * image.width + x) * 4 + 3] > Self.litAlpha }
        }
        return rows.isEmpty ? nil : rows
    }

    /// The highest alpha in each column, which is how a rendered row is read as a profile: the
    /// glyphs' ink, the halo around it, and where each of them stops.
    private static func columnAlphas(of image: RenderedImage) -> [UInt8] {
        var alphas = [UInt8](repeating: 0, count: image.width)
        for x in 0 ..< image.width {
            for y in 0 ..< image.height {
                alphas[x] = max(alphas[x], image.pixels[(y * image.width + x) * 4 + 3])
            }
        }
        return alphas
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

    /// The topmost row carrying ink inside a range of columns, so one band of a rendered row can be
    /// asked how high its glyph sits. `above` is how much alpha counts as ink — raised above the
    /// faint end for a band measured around a glowing character, where the halo reaches further than
    /// the band is inset.
    private static func topInkRow(of image: RenderedImage, columns: Range<Int>, above: UInt8 = 8) -> Int? {
        let columns = columns.clamped(to: 0 ..< image.width)
        for y in 0 ..< image.height {
            for x in columns where image.pixels[(y * image.width + x) * 4 + 3] > above {
                return y
            }
        }
        return nil
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
