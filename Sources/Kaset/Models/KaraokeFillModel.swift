import Foundation

// MARK: - KaraokeWord

/// One rendered word of a karaoke line: the text to draw plus the window over which
/// it fills with colour.
///
/// Words come from word timings when the provider supplies them. A line without
/// word timings is split into words whose fill windows sweep the line in reading
/// order, so line-synced lyrics get the same progressive wipe.
struct KaraokeWord: Equatable, Sendable {
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

    var durationMs: Double {
        max(1, self.fillEndMs - self.fillStartMs)
    }

    /// How much of the word is filled at a playback position: 0 is untouched, 1 is
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

    /// How much the word is emphasised at a playback position, 0...1.
    ///
    /// The word being sung swells as it is sung and settles as it lands. The
    /// envelope is measured in time rather than in fill, and both ends have zero
    /// slope, so a short word does not snap to full size in its first frames.
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

    /// Whether a lyric row should run on the display clock.
    ///
    /// Three rows run: the line being sung, the line after it (so its fill and swell are
    /// already moving when the highlight arrives), and — briefly — the line that has just
    /// finished.
    ///
    /// The trailing line is not about its own fill, which is complete either way. It is
    /// about how a line *leaves*: a row that is not live renders a settled frame, and a row
    /// that is live renders from the clock, which are two different subtrees. Switching
    /// between them in the same update that changes the row's status replaces that subtree
    /// mid-transition, and SwiftUI does not animate a subtree it replaces — which made the
    /// line that had just finished snap down to its resting size instead of scaling down to
    /// it, while the line arriving behind it, whose row stayed live throughout, animated
    /// correctly.
    ///
    /// Keeping the row live until the clock is past the line's end makes the switch happen
    /// when the two frames are pixel-identical (the fill is complete and the halo has
    /// settled), so the swap is invisible and the scale-down is left to animate.
    static func isLiveRow(
        lineIndex: Int,
        currentLineIndex: Int?,
        lineEndMs: Double?,
        clockMs: Double,
        timing: KaraokeTiming = .standard
    ) -> Bool {
        guard let currentLineIndex else { return false }
        if lineIndex == currentLineIndex || lineIndex == currentLineIndex + 1 { return true }
        guard lineIndex == currentLineIndex - 1, let lineEndMs else { return false }
        return clockMs < lineEndMs + timing.trailingSettleMs
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
