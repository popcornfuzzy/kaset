import Foundation

// MARK: - PodcastTranscriptLine

/// A single timed transcript paragraph for a podcast episode.
///
/// YouTube's caption track is segmented for subtitles (a few words per cue), so
/// consecutive cues are merged into readable paragraphs before display — see
/// ``PodcastTranscriptParser``.
struct PodcastTranscriptLine: Identifiable, Equatable, Sendable {
    let id: UUID
    /// Timestamp in milliseconds when this paragraph starts.
    let timeInMs: Int
    /// Duration in milliseconds covered by this paragraph.
    let durationMs: Int
    /// The transcript text for this paragraph.
    let text: String

    init(timeInMs: Int, durationMs: Int, text: String) {
        self.id = UUID()
        self.timeInMs = timeInMs
        self.durationMs = durationMs
        self.text = text
    }

    /// Timestamp in milliseconds when this paragraph ends.
    var endTimeInMs: Int {
        self.timeInMs + self.durationMs
    }
}

// MARK: - PodcastChapter

/// One chapter of a podcast episode.
///
/// Chapters come from the timestamped lines creators put in the episode description — the same
/// source YouTube uses to build its own chapter list — see ``PodcastTranscriptParser``.
struct PodcastChapter: Identifiable, Equatable, Sendable {
    let id: UUID
    /// Chapter heading, with the timestamp removed.
    let title: String
    /// Timestamp in milliseconds where the chapter starts.
    let startTimeMs: Int

    init(title: String, startTimeMs: Int) {
        self.id = UUID()
        self.title = title
        self.startTimeMs = startTimeMs
    }

    /// Whether `timeMs` falls inside this chapter, given where the next one starts.
    func contains(_ timeMs: Int, nextChapterStartMs: Int?) -> Bool {
        guard timeMs >= self.startTimeMs else { return false }
        guard let nextChapterStartMs else { return true }
        return timeMs < nextChapterStartMs
    }
}

// MARK: - PodcastTranscriptRow

/// A paragraph row of the transcript list.
struct PodcastTranscriptRow: Identifiable, Equatable, Sendable {
    /// The paragraph's identity, which doubles as the scroll anchor the transcript follows.
    let id: UUID
    /// Index of this paragraph in the episode's full transcript, used for spoken/current status.
    let lineIndex: Int
    /// The paragraph itself.
    let line: PodcastTranscriptLine

    /// Wraps transcript paragraphs as rows, keeping their index for status lookups.
    static func rows(for lines: [PodcastTranscriptLine]) -> [PodcastTranscriptRow] {
        lines.enumerated().map { index, line in
            PodcastTranscriptRow(id: line.id, lineIndex: index, line: line)
        }
    }
}

// MARK: - PodcastTranscriptSection

/// A chapter's slice of the transcript, ready for the sectioned transcript list.
struct PodcastTranscriptSection: Identifiable, Equatable, Sendable {
    /// Stable identity: the chapter's start time, or `-1` for a section without a chapter.
    let id: Int
    /// The chapter this section belongs to, or `nil` when the episode has no chapters.
    let chapter: PodcastChapter?
    /// Paragraph rows in this section, in playback order.
    let rows: [PodcastTranscriptRow]

    /// Groups transcript paragraphs under the episode's chapters.
    ///
    /// A chapter owns every paragraph from its start until the next one begins, so the headings
    /// line up with what is being read. Paragraphs before the first chapter keep their own section
    /// rather than being dropped, even though YouTube's own chapter rules require a 0:00 start.
    static func sections(
        chapters: [PodcastChapter],
        lines: [PodcastTranscriptLine]
    ) -> [PodcastTranscriptSection] {
        let rows = PodcastTranscriptRow.rows(for: lines)

        guard let firstChapter = chapters.first else {
            return [PodcastTranscriptSection(id: -1, chapter: nil, rows: rows)]
        }

        var sections: [PodcastTranscriptSection] = []

        let leadingRows = rows.filter { $0.line.timeInMs < firstChapter.startTimeMs }
        if !leadingRows.isEmpty {
            sections.append(PodcastTranscriptSection(id: -1, chapter: nil, rows: leadingRows))
        }

        for (index, chapter) in chapters.enumerated() {
            let nextStartMs = index + 1 < chapters.count ? chapters[index + 1].startTimeMs : nil
            let sectionRows = rows.filter { row in
                chapter.contains(row.line.timeInMs, nextChapterStartMs: nextStartMs)
            }
            sections.append(
                PodcastTranscriptSection(id: chapter.startTimeMs, chapter: chapter, rows: sectionRows)
            )
        }

        return sections
    }
}

// MARK: - PodcastTranscript

/// A timed transcript for a podcast episode, sourced from YouTube's caption track.
struct PodcastTranscript: Equatable, Sendable {
    /// Transcript paragraphs in playback order.
    let lines: [PodcastTranscriptLine]

    /// Chapters of the episode, in playback order and empty when the description has none.
    let chapters: [PodcastChapter]

    /// Language code reported by the caption track (for example `"en"`).
    let languageCode: String?

    /// Whether the text comes from YouTube's auto-generated caption track.
    let isAutoGenerated: Bool

    init(
        lines: [PodcastTranscriptLine],
        chapters: [PodcastChapter] = [],
        languageCode: String?,
        isAutoGenerated: Bool
    ) {
        self.lines = lines
        self.chapters = chapters
        self.languageCode = languageCode
        self.isAutoGenerated = isAutoGenerated
    }

    /// An empty transcript for episodes without a caption track.
    static let unavailable = PodcastTranscript(lines: [], languageCode: nil, isAutoGenerated: false)

    /// Whether the transcript has any displayable text.
    var isAvailable: Bool {
        !self.lines.isEmpty
    }

    /// Position of a line relative to the current playback time.
    enum LineStatus: Equatable {
        case previous
        case current
        case upcoming
    }

    func lineStatuses(at timeMs: Int) -> [LineStatus] {
        self.lines.map { line in
            if line.timeInMs > timeMs {
                return .upcoming
            }
            if timeMs - line.timeInMs >= line.durationMs, line.durationMs > 0 {
                return .previous
            }
            return .current
        }
    }

    /// Index of the paragraph being spoken at `timeMs` (milliseconds), if any.
    func currentLineIndex(atMilliseconds timeMs: Int) -> Int? {
        self.lineStatuses(at: timeMs).lastIndex(of: .current)
    }
}
