import Foundation

// MARK: - TimedWord

/// A single timed word for karaoke mode.
struct TimedWord: Equatable, Codable, Sendable {
    let timeInMs: Int
    let word: String
}

// MARK: - SyncedLyricLine

/// A single timed lyric line.
struct SyncedLyricLine: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    /// Timestamp in milliseconds when this line starts.
    let timeInMs: Int
    /// Duration in milliseconds (time until next line).
    var duration: Int
    /// The lyric text for this line.
    let text: String
    /// Optional word-level timing for karaoke mode.
    let words: [TimedWord]?

    init(timeInMs: Int, duration: Int, text: String, words: [TimedWord]?) {
        self.id = UUID()
        self.timeInMs = timeInMs
        self.duration = duration
        self.text = text
        self.words = words
    }

    private enum CodingKeys: String, CodingKey {
        case id, timeInMs, duration, text, words
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.timeInMs = try container.decode(Int.self, forKey: .timeInMs)
        self.duration = try container.decode(Int.self, forKey: .duration)
        self.text = try container.decode(String.self, forKey: .text)
        self.words = try container.decodeIfPresent([TimedWord].self, forKey: .words)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.timeInMs, forKey: .timeInMs)
        try container.encode(self.duration, forKey: .duration)
        try container.encode(self.text, forKey: .text)
        try container.encodeIfPresent(self.words, forKey: .words)
    }
}

// MARK: - SyncedLyrics

/// Represents synced lyrics with per-line timestamps.
struct SyncedLyrics: Equatable, Codable, Sendable {
    let lines: [SyncedLyricLine]
    let source: String

    static let defaultPauseGapThresholdMs = 600

    var isEmpty: Bool {
        self.lines.isEmpty
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
        let isPauseText = line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
