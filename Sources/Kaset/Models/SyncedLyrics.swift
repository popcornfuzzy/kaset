import Foundation

// MARK: - TimedWord

/// A single timed word for karaoke mode.
struct TimedWord: Equatable, Codable, Sendable {
    let timeInMs: Int
    let word: String
    /// Whether the word is a backing vocal sung over the line rather than part of
    /// the lead vocal. Apple Music TTML marks these with `ttm:role="x-bg"`.
    let isBackground: Bool

    init(timeInMs: Int, word: String, isBackground: Bool = false) {
        self.timeInMs = timeInMs
        self.word = word
        self.isBackground = isBackground
    }

    private enum CodingKeys: String, CodingKey {
        case timeInMs, word, isBackground
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.timeInMs = try container.decode(Int.self, forKey: .timeInMs)
        self.word = try container.decode(String.self, forKey: .word)
        // Absent in caches written before backing vocals were modelled.
        self.isBackground = try container.decodeIfPresent(Bool.self, forKey: .isBackground) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.timeInMs, forKey: .timeInMs)
        try container.encode(self.word, forKey: .word)
        if self.isBackground {
            try container.encode(true, forKey: .isBackground)
        }
    }
}

// MARK: - SyncedLyricLine

/// A single timed lyric line.
struct SyncedLyricLine: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    /// Timestamp in milliseconds when this line starts.
    let timeInMs: Int
    /// Duration in milliseconds (time until next line).
    var duration: Int
    /// The lead lyric text for this line. Backing vocals are not included.
    let text: String
    /// Optional word-level timing for karaoke mode.
    let words: [TimedWord]?
    /// Optional backing-vocal words sung over this line.
    ///
    /// Kept apart from `words` on purpose: a backing vocal overlaps the lead line
    /// in time and would otherwise be treated as the next word of the lead vocal,
    /// dragging the karaoke fill backwards and gluing the two together.
    let backgroundWords: [TimedWord]?

    init(timeInMs: Int, duration: Int, text: String, words: [TimedWord]?, backgroundWords: [TimedWord]? = nil, id: UUID? = nil) {
        self.id = id ?? UUID()
        self.timeInMs = timeInMs
        self.duration = duration
        self.text = text
        self.words = words
        self.backgroundWords = backgroundWords
    }

    /// The line's backing-vocal text, or `nil` when it has none.
    var backgroundText: String? {
        guard let backgroundWords, !backgroundWords.isEmpty else { return nil }
        let joined = backgroundWords.map(\.word).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// Whether the line carries only backing vocals, with no lead text.
    var isBackgroundOnly: Bool {
        self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(self.backgroundWords ?? []).isEmpty
    }

    /// The line as its own backing vocal, for rendering the backing words with the same
    /// karaoke machinery the lead line uses.
    ///
    /// `KaraokeLineLayout` reads a line's `words`, so the backing words are handed to it
    /// as the words of a line that is otherwise empty of lead text. The line's `id` is
    /// kept — the renderer keys layouts and SwiftUI identity by it — and the empty `text`
    /// is exactly what a backing-only line already looks like, so `isLineSynced` falls
    /// out of the backing words themselves rather than needing a special case. The fill
    /// windows come from `KaraokeFillModel.backgroundWords(for:)`, which reads
    /// `backgroundWords` and never this view, so the synthetic shape exists only to fit
    /// the layout's input.
    var backingVocalLine: SyncedLyricLine {
        SyncedLyricLine(
            timeInMs: self.timeInMs,
            duration: self.duration,
            text: "",
            words: self.backgroundWords,
            backgroundWords: nil,
            id: self.id
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, timeInMs, duration, text, words, backgroundWords
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.timeInMs = try container.decode(Int.self, forKey: .timeInMs)
        self.duration = try container.decode(Int.self, forKey: .duration)
        self.text = try container.decode(String.self, forKey: .text)
        self.words = try container.decodeIfPresent([TimedWord].self, forKey: .words)
        // Absent in caches written before backing vocals were modelled.
        self.backgroundWords = try container.decodeIfPresent([TimedWord].self, forKey: .backgroundWords)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.timeInMs, forKey: .timeInMs)
        try container.encode(self.duration, forKey: .duration)
        try container.encode(self.text, forKey: .text)
        try container.encodeIfPresent(self.words, forKey: .words)
        try container.encodeIfPresent(self.backgroundWords, forKey: .backgroundWords)
    }
}

// MARK: - SyncedLyrics

/// Represents synced lyrics with per-line timestamps.
struct SyncedLyrics: Equatable, Codable, Sendable {
    let lines: [SyncedLyricLine]
    let source: String
    /// Who supplied the lyrics, when the provider credits a person.
    let attribution: LyricsAttribution?

    init(lines: [SyncedLyricLine], source: String, attribution: LyricsAttribution? = nil) {
        self.lines = lines
        self.source = source
        self.attribution = attribution
    }

    static let defaultPauseGapThresholdMs = 600

    var isEmpty: Bool {
        self.lines.isEmpty
    }

    /// Whether any line carries per-word timings (karaoke-capable).
    var hasWordTiming: Bool {
        self.lines.contains { line in
            if let words = line.words { return !words.isEmpty }
            return false
        }
    }

    /// Whether any line carries backing vocals.
    var hasBackgroundVocals: Bool {
        self.lines.contains { !($0.backgroundWords ?? []).isEmpty }
    }


    enum LineStatus {
        case previous, current, upcoming
    }

    enum PauseDotStatus: Equatable {
        case notSung, active, sung
    }

    struct PauseInterlude: Equatable {
        let lineIndex: Int
        let lineId: UUID
        let startTimeMs: Int
        let endTimeMs: Int

        var durationMs: Int {
            max(1, self.endTimeMs - self.startTimeMs)
        }

        func dotStatuses(at timeMs: Int) -> [PauseDotStatus] {
            if timeMs < self.startTimeMs {
                return [.notSung, .notSung, .notSung]
            }

            if timeMs >= self.endTimeMs {
                return [.sung, .sung, .sung]
            }

            let relativeMs = Double(timeMs - self.startTimeMs)
            let segmentDurationMs = Double(self.durationMs) / 3.0
            let activeDotIndex = min(2, Int(relativeMs / segmentDurationMs))

            return (0 ..< 3).map { dotIndex in
                if dotIndex < activeDotIndex { return .sung }
                if dotIndex == activeDotIndex { return .active }
                return .notSung
            }
        }
    }

    func lineStatuses(at timeMs: Int) -> [LineStatus] {
        self.lines.map { line in
            if line.timeInMs > timeMs { return .upcoming }
            // If the time passed the start time + duration, it's previous
            if timeMs - line.timeInMs >= line.duration, line.duration > 0 { return .previous }
            return .current
        }
    }

    func currentLineIndex(at timeMs: Int) -> Int? {
        self.lineStatuses(at: timeMs).lastIndex(of: .current)
    }

    /// Whether a line carries nothing to sing: no lead text and no backing vocal.
    ///
    /// This is the shape a pause row has, and the shape an instrumental interlude takes
    /// when a provider spells it out instead of leaving it to the timeline.
    static func isSilent(_ line: SyncedLyricLine) -> Bool {
        line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (line.backgroundWords ?? []).isEmpty
    }

    /// The sheet with a pause row inserted for every interlude the provider left implicit
    /// as a gap in the timeline.
    ///
    /// Providers say "nothing is sung here" in one of two ways, and only the first gives
    /// the renderer a row to hang the dots on:
    ///
    /// - **Explicitly**, as a line with no text: an LRC line with nothing after its
    ///   timestamp, or a word-synced `<p begin end/>`. The parsers keep those.
    /// - **Implicitly**, as nothing at all — the previous line simply ends earlier than
    ///   the next one begins. This is what Apple Music's word-synced TTML does: its
    ///   paragraphs are contiguous *within* a line but skip whole bars *between* them, so
    ///   there is no empty paragraph anywhere in it.
    ///
    /// Without this the dots never appear in word-by-word mode, which is the mode they
    /// are wanted in: every word-synced source takes the second route, so the sheet it
    /// produces has no silent line anywhere for the renderer to find. Measured against
    /// the real payloads, that is the whole of the bug — a played-and-parsed Autobahn
    /// library has 21 gaps of ≥600 ms between its 52 paragraphs and not one empty
    /// paragraph.
    ///
    /// The synthesized row covers the gap exactly, from the previous line's end to the
    /// next line's start. A gap whose far side is *already* a silent line is left alone:
    /// that line is the row the dots will render on, and adding another would put two rows
    /// in the same stretch of silence.
    ///
    /// Applied once, where a result is installed (see `SyncedLyricsService.apply`), never
    /// per frame: the rows are part of the sheet afterwards, so every index the display
    /// uses — the highlight, the scroll target, the row statuses — counts them.
    func withPauseInterludes(minimumGapMs: Int = Self.defaultPauseGapThresholdMs) -> SyncedLyrics {
        guard self.lines.count > 1 else { return self }

        var filled: [SyncedLyricLine] = []
        filled.reserveCapacity(self.lines.count)

        for (index, line) in self.lines.enumerated() {
            filled.append(line)

            guard index + 1 < self.lines.count else { continue }
            let next = self.lines[index + 1]
            // A silent line on the far side of the gap is already the pause row.
            guard !Self.isSilent(next) else { continue }

            let gapStart = line.timeInMs + max(line.duration, 0)
            let gapEnd = next.timeInMs
            guard gapEnd - gapStart >= minimumGapMs else { continue }

            filled.append(SyncedLyricLine(
                timeInMs: gapStart,
                duration: gapEnd - gapStart,
                text: "",
                words: nil,
                backgroundWords: nil
            ))
        }

        return SyncedLyrics(lines: filled, source: self.source, attribution: self.attribution)
    }

    func pauseInterlude(
        at timeMs: Int,
        minimumGapMs: Int = Self.defaultPauseGapThresholdMs
    ) -> PauseInterlude? {
        guard let currentIndex = self.currentLineIndex(at: timeMs) else { return nil }
        return self.pauseInterlude(forLineAt: currentIndex, minimumGapMs: minimumGapMs)
    }

    func pauseInterlude(
        forLineAt lineIndex: Int,
        minimumGapMs: Int = Self.defaultPauseGapThresholdMs
    ) -> PauseInterlude? {
        guard self.lines.indices.contains(lineIndex) else { return nil }

        let line = self.lines[lineIndex]
        // A line with backing vocals is not a pause: it has something to sing,
        // even though its lead text is empty.
        let isPauseText = line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (line.backgroundWords ?? []).isEmpty
        guard isPauseText else { return nil }
        guard line.duration >= minimumGapMs else { return nil }

        let startTimeMs = line.timeInMs
        let endTimeMs = line.timeInMs + line.duration
        guard endTimeMs > startTimeMs else { return nil }

        return PauseInterlude(
            lineIndex: lineIndex,
            lineId: line.id,
            startTimeMs: startTimeMs,
            endTimeMs: endTimeMs
        )
    }

    func isPauseLine(
        at lineIndex: Int,
        minimumGapMs: Int = Self.defaultPauseGapThresholdMs
    ) -> Bool {
        self.pauseInterlude(forLineAt: lineIndex, minimumGapMs: minimumGapMs) != nil
    }

    func pauseDotStatuses(
        forLineAt lineIndex: Int,
        at timeMs: Int,
        minimumGapMs: Int = Self.defaultPauseGapThresholdMs
    ) -> [PauseDotStatus] {
        guard let interlude = self.pauseInterlude(forLineAt: lineIndex, minimumGapMs: minimumGapMs) else {
            return [.notSung, .notSung, .notSung]
        }
        return interlude.dotStatuses(at: timeMs)
    }
}

// MARK: - LyricResult

/// Unified lyrics result that can hold either synced or plain lyrics.
enum LyricResult: Equatable, Codable, Sendable {
    case synced(SyncedLyrics)
    case plain(Lyrics)
    case unavailable

    var isAvailable: Bool {
        switch self {
        case let .synced(s): !s.isEmpty
        case let .plain(p): p.isAvailable
        case .unavailable: false
        }
    }

    private enum Kind: String, Codable {
        case synced, plain, unavailable
    }

    private enum CodingKeys: String, CodingKey {
        case kind, synced, plain
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .synced:
            self = .synced(try container.decode(SyncedLyrics.self, forKey: .synced))
        case .plain:
            self = .plain(try container.decode(Lyrics.self, forKey: .plain))
        case .unavailable:
            self = .unavailable
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .synced(value):
            try container.encode(Kind.synced, forKey: .kind)
            try container.encode(value, forKey: .synced)
        case let .plain(value):
            try container.encode(Kind.plain, forKey: .kind)
            try container.encode(value, forKey: .plain)
        case .unavailable:
            try container.encode(Kind.unavailable, forKey: .kind)
        }
    }
}
