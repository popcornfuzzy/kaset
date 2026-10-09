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

    /// Whether the source marks this line as the *other* singer's turn.
    ///
    /// Apple Music TTML attributes each paragraph to an agent — `<p ttm:agent="v2">` — and
    /// declares those agents in the document's metadata, so a duet alternates between two of
    /// them; the display draws the line that is not the song's first singer's against the
    /// trailing edge. Paxsenix says the same thing structurally, with an `oppositeTurn` flag
    /// on a content line and a `{v2}` voice marker in its ELRC. It is resolved where the
    /// source is read, because only the source knows which agent is the lead: resolving it
    /// later would need the whole document back (`SyncedLyrics.hasOppositeTurns`).
    let isOppositeTurn: Bool

    /// Backing-vocal text the source never timed.
    ///
    /// A line-synced source spells its backing vocal in the line's own text and times the line
    /// only as a whole — `You smart (you smart)` — so there is no onset to fill from and no
    /// window to fill over. The phrase is therefore not a `TimedWord`: handing it one would
    /// invent both, and the row would then be wiped word by word over a window nobody measured.
    /// It is drawn as a line-synced row instead — revealed whole when the line begins, the way
    /// the lead of a line-synced sheet is (see `backingVocalLine`).
    let untimedBackgroundText: String?

    init(
        timeInMs: Int,
        duration: Int,
        text: String,
        words: [TimedWord]?,
        backgroundWords: [TimedWord]? = nil,
        untimedBackgroundText: String? = nil,
        isOppositeTurn: Bool = false,
        id: UUID? = nil
    ) {
        self.id = id ?? UUID()
        self.timeInMs = timeInMs
        self.duration = duration
        self.text = text
        self.words = words
        self.backgroundWords = backgroundWords
        self.untimedBackgroundText = untimedBackgroundText
        self.isOppositeTurn = isOppositeTurn
    }

    /// The line's backing-vocal text, or `nil` when it has none.
    ///
    /// Word-timed backing words come first, then a phrase the source left untimed: one row can
    /// carry both readings, and both are part of what is sung over the line.
    var backgroundText: String? {
        var parts: [String] = []
        if let backgroundWords, !backgroundWords.isEmpty {
            let joined = backgroundWords.map(\.word).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { parts.append(joined) }
        }
        if let untimed = self.untimedBackgroundText?.trimmingCharacters(in: .whitespacesAndNewlines), !untimed.isEmpty {
            parts.append(untimed)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Whether the line carries a backing vocal at all, word-timed or not.
    ///
    /// A source that timed the line only as a whole still has something sung over it, and a row
    /// with something to sing must never be read as an interlude: this is what keeps a converted
    /// backing-only line out of the pause dots.
    var hasBackingVocal: Bool {
        self.backgroundText != nil
    }

    /// Whether the line carries only backing vocals, with no lead text.
    var isBackgroundOnly: Bool {
        self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && self.hasBackingVocal
    }

    /// The line as its own backing vocal, for rendering the backing words with the same
    /// karaoke machinery the lead line uses.
    ///
    /// `KaraokeLineLayout` reads a line's `words`, so a word-timed backing vocal is handed to it
    /// as the words of a line that is otherwise empty of lead text. The empty `text` is exactly
    /// what a backing-only line already looks like, so `isLineSynced` falls out of the backing
    /// words themselves rather than needing a special case.
    ///
    /// A phrase the source never timed has no words to hand over: it goes on the line's `text`
    /// instead, which makes the row **line-synced** — `isLineSynced` falls out of the absent
    /// words — so it is revealed whole rather than wiped word by word over a window nobody
    /// measured. The two readings are never mixed on one row: a phrase that is only partly timed
    /// is read as untimed, because a wipe needs every one of its words to have an onset.
    ///
    /// The line's `id` is kept — the renderer keys layouts and SwiftUI identity by it — and the
    /// fill windows of a word-timed row come from `KaraokeFillModel.backgroundWords(for:)`, which
    /// reads `backgroundWords` and never this view, so the synthetic shapes exist only to fit the
    /// layout's input.
    var backingVocalLine: SyncedLyricLine {
        let timedWords = (self.backgroundWords ?? []).isEmpty ? nil : self.backgroundWords
        let untimed = self.untimedBackgroundText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isWordTimed = timedWords != nil && (untimed ?? "").isEmpty

        return SyncedLyricLine(
            timeInMs: self.timeInMs,
            duration: self.duration,
            text: isWordTimed ? "" : self.backgroundText ?? "",
            words: isWordTimed ? timedWords : nil,
            backgroundWords: nil,
            id: self.id
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, timeInMs, duration, text, words, backgroundWords, untimedBackgroundText, isOppositeTurn
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
        self.untimedBackgroundText = try container.decodeIfPresent(String.self, forKey: .untimedBackgroundText)
        // Absent in caches written before singer turns were modelled.
        self.isOppositeTurn = try container.decodeIfPresent(Bool.self, forKey: .isOppositeTurn) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.timeInMs, forKey: .timeInMs)
        try container.encode(self.duration, forKey: .duration)
        try container.encode(self.text, forKey: .text)
        try container.encodeIfPresent(self.words, forKey: .words)
        try container.encodeIfPresent(self.backgroundWords, forKey: .backgroundWords)
        try container.encodeIfPresent(self.untimedBackgroundText, forKey: .untimedBackgroundText)
        // Only written when true, the way `TimedWord.isBackground` is: a false is the default
        // every document without agents gets, and writing it would grow every cache file.
        if self.isOppositeTurn {
            try container.encode(true, forKey: .isOppositeTurn)
        }
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
        self.lines.contains { $0.hasBackingVocal }
    }

    /// Whether the sheet attributes any line to a singer other than its first one, so the
    /// display knows whether this is a duet at all.
    var hasOppositeTurns: Bool {
        self.lines.contains { $0.isOppositeTurn }
    }

    /// The edge the row at an index is drawn against.
    ///
    /// A line answers for itself (`isOppositeTurn`). A pause row does not: nothing is sung on
    /// it and it has no singer of its own — it is the silence *inside* somebody's section — so
    /// it follows the line above it, which is the line it is a pause in. A row that is itself a
    /// pause is stepped over on the way up, so two interludes in a row both follow the last
    /// line that was actually sung.
    func isTrailingAligned(at lineIndex: Int, minimumGapMs: Int = Self.defaultPauseGapThresholdMs) -> Bool {
        guard self.lines.indices.contains(lineIndex) else { return false }
        guard self.isPauseLine(at: lineIndex, minimumGapMs: minimumGapMs) else {
            return self.lines[lineIndex].isOppositeTurn
        }

        for index in stride(from: lineIndex - 1, through: 0, by: -1)
            where !self.isPauseLine(at: index, minimumGapMs: minimumGapMs)
        {
            return self.lines[index].isOppositeTurn
        }
        // Nothing above it was sung, so the row's own declaration is all there is.
        return self.lines[lineIndex].isOppositeTurn
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

        /// Roughly how long one bounce of the dot that is moving should take. The
        /// interlude's own length decides how many of them fit in the dot's turn, so
        /// the dot is always at rest when its turn begins and when it ends.
        static let targetBounceMs: Double = 750

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

        /// How far the dot that is bouncing has risen, 0...1, at a playback position.
        ///
        /// The bounce is timed by the interlude, not by the wall clock, which is what makes
        /// it work at every length an interlude can be. Each dot's turn holds a whole number
        /// of bounces — chosen so one takes about `targetBounceMs` — and each bounce leaves
        /// and arrives at rest, because the envelope is `(1 - cos) / 2`: it is zero with zero
        /// slope at both ends of a cycle. So the dot never appears mid-air, never runs at a
        /// rate that a longer or shorter gap makes look frantic or stuck, and the last frame
        /// of the interlude is the still one the settled row draws. A dot driven by the wall
        /// clock had none of that: it started wherever the clock happened to be, so a 600 ms
        /// gap caught it half-way through a rise and a 30 s one kept the same 720 ms period
        /// for forty bounces.
        func dotLift(at timeMs: Int) -> Double {
            let turnMs = Double(self.durationMs) / 3.0
            guard turnMs > 0, timeMs >= self.startTimeMs, timeMs < self.endTimeMs else { return 0 }

            let relativeMs = Double(timeMs - self.startTimeMs)
            let elapsedInTurnMs = relativeMs - min(2, floor(relativeMs / turnMs)) * turnMs
            let bounces = max(1, (turnMs / Self.targetBounceMs).rounded())
            let phase = elapsedInTurnMs / (turnMs / bounces)
            return (1 - cos(2 * .pi * phase)) / 2
        }
    }

    /// What the three pause dots show at a playback position: which of them has been
    /// sung, which is moving, and how far the moving one has risen.
    struct PauseDots: Equatable {
        let statuses: [PauseDotStatus]
        /// 0...1 rise of the dot that is bouncing; 0 when none of them is.
        let lift: Double

        static let resting = PauseDots(statuses: [.notSung, .notSung, .notSung], lift: 0)
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
            && !line.hasBackingVocal
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

    /// The silence a pause row stands for, or `nil` when the row is not a pause.
    ///
    /// The row's own shape decides whether it is a pause at all — nothing to sing, for at
    /// least `minimumGapMs` (see `isPauseShape`). *When* that pause begins is a second
    /// question, and the row's own timestamp is not always the answer: a backing vocal can
    /// outlast the line it sits under. Apple Music writes a phrase whose onsets lie past its
    /// own paragraph's end — the `(High, the way that you're stuck in my head)` under an
    /// `I'm sick, I'm sick` paragraph that has already run out — and that phrase fills right
    /// through the gap the sheet calls an interlude. Nothing is sung during a pause, so the
    /// silence begins where the row above stopped sounding: `KaraokeFillModel.settleBoundaryMs`,
    /// the same boundary the highlight waits for and the row above stays on the display clock
    /// for. The dots and the highlight therefore cannot disagree about when it started.
    ///
    /// A row that the row above fills right to its end has no silence of its own left to
    /// show: the window collapses and the dots read as already sung.
    func pauseInterlude(
        forLineAt lineIndex: Int,
        minimumGapMs: Int = Self.defaultPauseGapThresholdMs
    ) -> PauseInterlude? {
        guard self.lines.indices.contains(lineIndex) else { return nil }

        let line = self.lines[lineIndex]
        guard Self.isPauseShape(line, minimumGapMs: minimumGapMs) else { return nil }

        let endTimeMs = line.timeInMs + line.duration
        let startTimeMs = min(max(line.timeInMs, self.soundingEndMs(beforeLineAt: lineIndex)), endTimeMs)

        return PauseInterlude(
            lineIndex: lineIndex,
            lineId: line.id,
            startTimeMs: startTimeMs,
            endTimeMs: endTimeMs
        )
    }

    /// Whether a row is a pause on its own account: nothing to sing, for at least the minimum
    /// gap. Blind to the row before it on purpose — whether a pause has *begun* is a question
    /// about time rather than about shape, and the dots are drawn on the row either way.
    private static func isPauseShape(_ line: SyncedLyricLine, minimumGapMs: Int) -> Bool {
        Self.isSilent(line) && line.duration >= minimumGapMs
    }

    /// When the row above a given row has stopped sounding: the later of its declared end and
    /// the end of its own last fill ramp, lead and backing alike (`KaraokeFillModel.settleBoundaryMs`).
    /// `0` when there is no row above, which no declared start is ever behind.
    private func soundingEndMs(beforeLineAt lineIndex: Int) -> Int {
        guard self.lines.indices.contains(lineIndex - 1) else { return 0 }
        return Int(KaraokeFillModel.settleBoundaryMs(for: self.lines[lineIndex - 1]).rounded())
    }

    /// Whether a row draws the pause dots.
    ///
    /// Asked of the row's shape alone, and not through `pauseInterlude`, because this is the
    /// question every row of the sheet is asked on every render and the interlude is a question
    /// about the row *above* it as well.
    func isPauseLine(
        at lineIndex: Int,
        minimumGapMs: Int = Self.defaultPauseGapThresholdMs
    ) -> Bool {
        guard self.lines.indices.contains(lineIndex) else { return false }
        return Self.isPauseShape(self.lines[lineIndex], minimumGapMs: minimumGapMs)
    }

    /// The three dots' state at a playback position, for a row that is a pause.
    ///
    /// Taken together — which dots are lit and how far the moving one has risen — because
    /// both come from the same interlude and from the same display position, and a dot drawn
    /// from one position and lit from another is a dot that jumps. The rise is a plain value
    /// here rather than a second animation of its own: the row already redraws per frame off
    /// the display clock, so the dots need no timeline of their own and are synchronized with
    /// everything else on the row.
    func pauseDots(
        forLineAt lineIndex: Int,
        at timeMs: Int,
        minimumGapMs: Int = Self.defaultPauseGapThresholdMs
    ) -> PauseDots {
        guard let interlude = self.pauseInterlude(forLineAt: lineIndex, minimumGapMs: minimumGapMs) else {
            return .resting
        }
        return PauseDots(
            statuses: interlude.dotStatuses(at: timeMs),
            lift: interlude.dotLift(at: timeMs)
        )
    }

    /// Which of the three dots is lit, without the bounce. For callers that only ask about
    /// the state of the pause rather than drawing it.
    func pauseDotStatuses(
        forLineAt lineIndex: Int,
        at timeMs: Int,
        minimumGapMs: Int = Self.defaultPauseGapThresholdMs
    ) -> [PauseDotStatus] {
        self.pauseDots(forLineAt: lineIndex, at: timeMs, minimumGapMs: minimumGapMs).statuses
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
