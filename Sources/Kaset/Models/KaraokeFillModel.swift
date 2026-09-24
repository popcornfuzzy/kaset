// CoreGraphics for `CGFloat`: splitting a word's fill window between its characters is
// deliberately weighted by their measured widths, so the timings depend on the type face and
// size the renderer will draw with, even though the model measures nothing itself.
import CoreGraphics
import Foundation

// MARK: - KaraokeFillUnit

/// A unit of lyric text that fills over its own window: a word, or one character within a
/// word.
///
/// The envelopes live here rather than on either type, because the two units are the same
/// animation at two scales. A word's window is sliced into one window per character
/// (`KaraokeFillModel.characters(for:weightedBy:)`), and each slice drives exactly the fill,
/// glow and lift the word used to drive as a whole.
protocol KaraokeFillUnit {
    /// Start of the fill ramp, in milliseconds.
    var fillStartMs: Double { get }
    /// End of the fill ramp, in milliseconds.
    var fillEndMs: Double { get }
}

extension KaraokeFillUnit {
    var durationMs: Double {
        max(1, self.fillEndMs - self.fillStartMs)
    }

    /// How much of the unit is filled at a playback position: 0 is untouched, 1 is
    /// fully sung.
    func fill(at timeMs: Double) -> Double {
        KaraokeFillModel.ease(clamped: (timeMs - self.fillStartMs) / self.durationMs)
    }

    /// Entry progress for a line a provider timed only as a whole: 0 before the line,
    /// 1 shortly after it starts, and 1 for the rest of it.
    ///
    /// Line-synced lyrics are read as they are sung, so the line appears at once and
    /// then stays fully lit. It never brightens gradually across its own duration: the
    /// words have to be legible while they are being sung.
    func appearProgress(at timeMs: Double, appearMs: Double = 200) -> Double {
        KaraokeFillModel.smoothstep((timeMs - self.fillStartMs) / max(1, appearMs))
    }

    /// How strongly the halo shows for such a line, 0...1.
    ///
    /// It blooms in with the appear ramp and settles back out to a soft residue, so the
    /// line arrives with some light and is then calm to read.
    func haloStrength(at timeMs: Double, appearMs: Double = 200, settleMs: Double = 600) -> Double {
        let elapsed = timeMs - self.fillStartMs
        guard elapsed > 0 else { return 0 }

        let rise = KaraokeFillModel.smoothstep(elapsed / max(1, appearMs))
        let settle = KaraokeFillModel.smoothstep((elapsed - appearMs) / max(1, settleMs))
        return rise * (1 - settle * 0.8)
    }

    /// Strength of the glow on the unit being sung, 0...1.
    ///
    /// The glow blooms in behind the leading edge and calms again as the unit lands,
    /// reaching **exactly zero** as it completes. It used to be a function of the
    /// fill, which meant it was still at full strength on the frame the word finished and
    /// then vanished with it — a full-brightness halo disappearing in a single frame reads
    /// as the word jumping smaller, and on the last word of a line that lands while the
    /// line is scaling down, so the line looked like it jumped in place instead of easing
    /// out.
    ///
    /// Both ends have zero slope and it ends with the unit, so a word can be finished
    /// without anything on it changing — which is also what keeps the frame a row settles
    /// to identical to the one it was already showing.
    func glowStrength(at timeMs: Double, riseMs: Double = 130, fadeMs: Double = 170) -> Double {
        let elapsed = timeMs - self.fillStartMs
        guard elapsed > 0 else { return 0 }
        let remaining = self.durationMs - elapsed
        guard remaining > 0 else { return 0 }

        let rise = KaraokeFillModel.smoothstep(elapsed / min(riseMs, self.durationMs * 0.4))
        let fade = KaraokeFillModel.smoothstep(remaining / min(fadeMs, self.durationMs * 0.5))
        return rise * fade
    }

    /// How much the unit being sung is lifted at a playback position, 0...1.
    ///
    /// The unit rises as it is sung and settles as it lands. The envelope is measured in
    /// time rather than in fill, and both ends have zero slope, so a short window does not
    /// snap to full lift in its first frames. It is deliberately not a *size*: see the
    /// renderer for why a unit must not be scaled.
    func swell(at timeMs: Double, attackMs: Double = 130, releaseMs: Double = 170) -> Double {
        let elapsed = timeMs - self.fillStartMs
        guard elapsed > 0 else { return 0 }
        let remaining = self.durationMs - elapsed
        guard remaining > 0 else { return 0 }

        return min(
            KaraokeFillModel.smoothstep(elapsed / min(attackMs, self.durationMs / 2)),
            KaraokeFillModel.smoothstep(remaining / min(releaseMs, self.durationMs / 2))
        )
    }
}

// MARK: - KaraokeWord

/// One rendered word of a karaoke line: the text to draw plus the window over which
/// it fills with colour.
///
/// Words come from word timings when the provider supplies them. A line without
/// word timings is split into words whose fill windows sweep the line in reading
/// order, so line-synced lyrics get the same progressive wipe.
struct KaraokeWord: Equatable, Sendable, KaraokeFillUnit {
    /// Index of the word within its line.
    let index: Int
    /// The word's text, without surrounding whitespace. Gaps between words are laid
    /// out by the renderer, so a word never carries padding of its own.
    let text: String
    /// Whether this word starts a new word rather than continuing the previous one.
    ///
    /// Providers signal a word boundary with a leading space and write the syllables
    /// of one word as separate runs without one, so this is what keeps a syllable
    /// split word rendered as a single word.
    let isNewWord: Bool
    /// Start of the fill ramp, in milliseconds.
    let fillStartMs: Double
    /// End of the fill ramp, in milliseconds.
    let fillEndMs: Double
}

// MARK: - KaraokeCharacter

/// One character of a karaoke word: the text to draw plus its own slice of the word's fill
/// window.
///
/// The character is the unit that lifts. A word's emphasis used to be one translation of
/// the whole word; slicing the word's window per character turns it into a wave that follows
/// the fill edge, so the character being sung rises and settles while the ones around it stay
/// at rest. The slices tile the word's window exactly, so the word still fills over exactly
/// the interval it always did.
struct KaraokeCharacter: Equatable, Sendable, KaraokeFillUnit {
    /// Index of the character within its word.
    let index: Int
    /// One grapheme cluster of the word, as the renderer draws it.
    let text: String
    /// Start of this character's slice of the word's fill ramp, in milliseconds.
    let fillStartMs: Double
    /// End of this character's slice of the word's fill ramp, in milliseconds.
    let fillEndMs: Double
}

// MARK: - KaraokeFillModel

/// Pure timing model behind the karaoke wipe.
///
/// Kept free of SwiftUI so the fill behaviour — word slots, attack lead, release
/// tail, and the line-level fallback sweep — is unit-testable without rendering.
enum KaraokeFillModel {
    /// How much faster the edge moves mid-word than at the word's edges. The edge
    /// articulates a word instead of sweeping at the constant speed of a progress
    /// bar, while staying monotone.
    private static let articulation = 0.22

    /// A 0...1 ramp that leaves and arrives with zero slope, so an envelope built
    /// from it starts and ends without a visible step.
    static func smoothstep(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// Maps an unclamped linear progress to an eased 0...1 fill.
    static func ease(clamped raw: Double) -> Double {
        guard raw > 0 else { return 0 }
        guard raw < 1 else { return 1 }
        // The derivative, 1 - articulation·cos(2πt), stays positive for
        // articulation < 1, so the fill never moves backwards.
        return raw - Self.articulation * sin(2 * .pi * raw) / (2 * .pi)
    }

    /// The words to render for a line, each with its own fill window.
    ///
    /// A line the provider timed only as a whole yields **one** word covering the whole
    /// line. Word timings are never invented for it: line-synced lyrics are sung as a
    /// line, so they are filled as a line.
    static func words(for line: SyncedLyricLine, timing: KaraokeTiming = .standard) -> [KaraokeWord] {
        let timedWords = (line.words ?? []).filter { !$0.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !timedWords.isEmpty else { return self.lineWord(for: line, timing: timing) }
        return self.timedWords(timedWords, line: line, timing: timing)
    }

    /// A word split into its characters, each handed the slice of the word's fill window that
    /// matches the share of the word's width it occupies.
    ///
    /// The edge therefore crosses the word at the speed of the text it is crossing — a wide
    /// `m` holds it for longer than a narrow `i` — while the word as a whole still fills over
    /// exactly the interval it always did: the slices tile the word's window, so the first
    /// character starts where the word starts and the last ends where the word ends.
    ///
    /// `widths` are the measured advances of the characters, in order; the model measures
    /// nothing itself. Text whose widths are missing or all zero falls back to one equal share
    /// per character, which tiles the same way.
    static func characters(for word: KaraokeWord, weightedBy widths: [CGFloat]) -> [KaraokeCharacter] {
        let characters = Array(word.text)
        guard !characters.isEmpty else { return [] }

        let total = widths.reduce(0, +)
        let shares: [Double] = if widths.count == characters.count, total > 0 {
            widths.map { Double($0 / total) }
        } else {
            Array(repeating: 1 / Double(characters.count), count: characters.count)
        }

        var offset = 0.0
        return characters.enumerated().map { index, character in
            let start = offset
            offset += shares[index]
            return KaraokeCharacter(
                index: index,
                text: String(character),
                fillStartMs: word.fillStartMs + word.durationMs * start,
                // The last slice ends where the word does, so a clamp inside `durationMs`
                // cannot leave a sliver of the word unfilled at its end.
                fillEndMs: index == characters.count - 1
                    ? word.fillEndMs
                    : word.fillStartMs + word.durationMs * offset
            )
        }
    }

    /// The playback position to render a line at when it is not the line being sung.
    ///
    /// Finished lines read as fully sung and upcoming lines as untouched, which is
    /// what keeps the live display clock confined to the line that is moving.
    static func staticTimeMs(
        for status: SyncedLyrics.LineStatus,
        line: SyncedLyricLine,
        timing: KaraokeTiming = .standard
    ) -> Double {
        self.staticTimeMs(for: status, words: self.words(for: line, timing: timing), line: line)
    }

    /// As `staticTimeMs(for:line:timing:)`, for callers that already hold the line's
    /// words — the renderer derives them once per line, not once per frame.
    static func staticTimeMs(
        for status: SyncedLyrics.LineStatus,
        words: [KaraokeWord],
        line: SyncedLyricLine
    ) -> Double {
        switch status {
        case .previous:
            // A stretch with no words at all (an instrumental gap) reads as finished
            // from its own end time.
            return words.map(\.fillEndMs).max() ?? Double(line.timeInMs + max(line.duration, 1))
        case .current, .upcoming:
            // Just before the first ramp, so nothing is filled yet.
            return (words.map(\.fillStartMs).min() ?? Double(line.timeInMs)) - 1
        }
    }

    /// When a line stops being sung: the later of its declared end and the end of its last fill
    /// ramp.
    ///
    /// The two can disagree. Providers are not obliged to give a duration, and a line with none
    /// would otherwise stop being sung while its last word was still filling. This single
    /// position answers both questions the display asks about a line that is finishing — is it
    /// still on the display clock, and has the highlight moved on — so the two can never
    /// disagree with each other either.
    static func settleBoundaryMs(for line: SyncedLyricLine, timing: KaraokeTiming = .standard) -> Double {
        let declaredEnd = Double(line.timeInMs) + max(Double(line.duration), 0)
        let contentEnd = self.words(for: line, timing: timing).map(\.fillEndMs).max() ?? 0
        return max(declaredEnd, contentEnd)
    }

    /// Index of the line being sung at a playback position.
    ///
    /// This is the line that is *being sung*, not the line the sheet is scrolling towards: a
    /// line stops being the one being sung when its own content is settled
    /// (`settleBoundaryMs`) — just after its last word lands, and exactly then for a line whose
    /// duration the provider never gave. Only at that point does the line that is leaving begin
    /// to dim, shrink and recede, so a line reaches its sung state before it starts to go.
    ///
    /// It is deliberately not computed with `KaraokeTiming.scrollLookaheadMs`. That lead exists
    /// so the *scroll* has the line in place before its first word is sung; letting it move the
    /// highlight too meant a line began leaving up to 120 ms before it had finished being sung,
    /// which is what made the line that had just finished look like it never settled.
    ///
    /// The declared rule is the cheap one — the last line that has started and has not run past
    /// its own duration. Only a line whose fill overran that duration keeps the highlight, and
    /// deciding that costs one comparison against that one line's fill windows. Because the
    /// declared rule has already stepped past the earlier line, its declared end is behind us,
    /// so testing against its content end is testing against `settleBoundaryMs`.
    static func highlightIndex(
        in lyrics: SyncedLyrics,
        at timeMs: Int,
        timing: KaraokeTiming = .standard
    ) -> Int? {
        guard let declared = lyrics.currentLineIndex(at: timeMs) else { return nil }
        guard declared > 0 else { return declared }

        let earlier = lyrics.lines[declared - 1]
        let contentEnd = self.words(for: earlier, timing: timing).map(\.fillEndMs).max() ?? 0
        return Double(timeMs) < contentEnd ? declared - 1 : declared
    }

    /// Whether a lyric row should run on the display clock.
    ///
    /// Three rows run: the line being sung, the line after it (so its fill and swell are
    /// already moving when the highlight arrives), and the line that has just finished, until
    /// the clock is past `settleBoundaryMs`.
    ///
    /// That last window is not about the row's own fill, which is complete either way. It is
    /// about the hand-off: a row that is not live renders one settled frame and stops, and the
    /// departure of the line that has just been sung is Core Animation's from there on — a
    /// frozen raster being scaled, dimmed and blurred, rather than a half-filled line being
    /// re-drawn and re-rasterized every frame while it shrinks. The hand-off itself is a value
    /// change inside an unchanged subtree (`KaraokeTimeSource` keeps one timeline and pauses
    /// it), so which frame it lands on is no longer load-bearing; what it lands on is the frame
    /// the row was already showing, because everything the fill does has finished by
    /// `settleBoundaryMs`.
    ///
    /// The line is taken lazily rather than as a precomputed end time: the words behind
    /// `settleBoundaryMs` are only needed for the one row that has just finished — every
    /// other row leaves through one of the index checks above — and deriving them for every
    /// row of a sheet on every render is exactly the per-render cost this pipeline avoids.
    static func isLiveRow(
        lineIndex: Int,
        currentLineIndex: Int?,
        line: SyncedLyricLine?,
        clockMs: Double,
        timing: KaraokeTiming = .standard
    ) -> Bool {
        guard let currentLineIndex else { return false }
        if lineIndex == currentLineIndex || lineIndex == currentLineIndex + 1 { return true }
        guard lineIndex == currentLineIndex - 1, let line else { return false }
        return clockMs < self.settleBoundaryMs(for: line, timing: timing)
    }

    // MARK: - Word-timed lines

    private static func timedWords(
        _ words: [TimedWord],
        line: SyncedLyricLine,
        timing: KaraokeTiming
    ) -> [KaraokeWord] {
        let lineEnd = line.duration > 0 ? Double(line.timeInMs + line.duration) : nil

        return words.indices.map { index in
            let start = Double(words[index].timeInMs)
            let rawEnd: Double = if index + 1 < words.count {
                Double(words[index + 1].timeInMs)
            } else if let lineEnd {
                lineEnd
            } else {
                start + timing.fallbackWordMs
            }

            // Providers timestamp onsets only, so an unusually long gap between two
            // onsets should settle rather than crawl across the screen.
            let end = min(max(rawEnd, start + timing.minimumFillMs), start + timing.maximumFillMs)
            let raw = words[index].word
            return self.word(
                index: index,
                text: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                isNewWord: index == 0 || raw.hasPrefix(" ") || raw.hasPrefix("\t"),
                start: start,
                end: end,
                timing: timing
            )
        }
    }

    // MARK: - Lines without word timings

    /// The whole line as a single fill unit.
    ///
    /// Unlike a word-timed line, the fill is not capped by `maximumFillMs`: a line is
    /// genuinely being sung for its whole duration, so its fill lasts that long.
    private static func lineWord(for line: SyncedLyricLine, timing: KaraokeTiming) -> [KaraokeWord] {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let start = Double(line.timeInMs)
        let end = start + (line.duration > 0 ? Double(line.duration) : timing.fallbackLineMs)
        return [self.word(index: 0, text: text, isNewWord: true, start: start, end: end, timing: timing)]
    }

    // MARK: - Span construction

    private static func word(
        index: Int,
        text: String,
        isNewWord: Bool,
        start: Double,
        end: Double,
        timing: KaraokeTiming
    ) -> KaraokeWord {
        // The fill leads the onset slightly and lands just before the next onset, so
        // the edge is already moving when the word is heard.
        let fillStartMs = start - timing.attackLeadMs
        var fillEndMs = end - timing.releaseTailMs
        if fillEndMs - fillStartMs < timing.minimumFillMs {
            fillEndMs = fillStartMs + timing.minimumFillMs
        }
        return KaraokeWord(
            index: index,
            text: text,
            isNewWord: isNewWord,
            fillStartMs: fillStartMs,
            fillEndMs: fillEndMs
        )
    }
}
