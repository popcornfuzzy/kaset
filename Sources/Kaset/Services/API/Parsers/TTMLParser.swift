import Foundation

// MARK: - TTMLParser

/// Parses Apple Music TTML (the `itunes:timing="Word"` format served by the
/// Paxsenix, BetterLyrics and Unison integrations) into Kaset's `SyncedLyrics`.
///
/// Each `<p>` becomes a line; its `<span>` children become per-word timings.
/// Word spacing comes from the source — whitespace between spans marks a word
/// boundary, while syllable continuations have no inter-span whitespace and are
/// glued together.
///
/// Spans carrying a translation or romanization role (`ttm:role="x-translation"`
/// / `"x-roman"`) are skipped: they restate the line in another script and would
/// otherwise be appended as extra (out-of-sync) words.
///
/// A `<span ttm:role="x-bg">` groups the backing vocals sung over the line. Those
/// words are collected into `backgroundWords` rather than the lead line: they
/// overlap the lead in time, so mixing them in would glue their text onto the
/// lead line and drag the karaoke fill backwards.
enum TTMLParser {
    /// Parses TTML into word- or line-synced lyrics.
    ///
    /// A document whose paragraphs carry no timing at all is not synced lyrics —
    /// the same payload BetterLyrics serves for a song that only has unsynced
    /// lyrics. `parse` returns `nil` for it rather than stacking every paragraph
    /// on the timeline at zero, leaving the caller to read it with
    /// `plainLyrics(_:source:)`.
    static func parse(_ raw: String, source: String) -> SyncedLyrics? {
        guard let delegate = Self.parseDocument(raw), delegate.sawTiming, !delegate.lines.isEmpty else {
            return nil
        }
        return SyncedLyrics(lines: delegate.lines, source: source)
    }

    /// The document's text as plain lyrics, read only from a document that
    /// carries text but no timing.
    ///
    /// Returns `nil` for a timed document (that belongs to `parse`), for a
    /// document with no readable text, and for anything that is not TTML.
    static func plainLyrics(_ raw: String, source: String) -> Lyrics? {
        guard let delegate = Self.parseDocument(raw), !delegate.sawTiming else { return nil }
        let text = delegate.lines
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        return Lyrics(text: text, source: source)
    }

    private static func parseDocument(_ raw: String) -> TTMLParserDelegate? {
        guard let data = raw.data(using: .utf8) else { return nil }
        let delegate = TTMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate
    }
}

// MARK: - TTMLParserDelegate

private final class TTMLParserDelegate: NSObject, XMLParserDelegate {
    var lines: [SyncedLyricLine] = []

    /// Whether the document declared any timing at all — a `<p>` window or a
    /// timed `<span>`. An untimed document is not synced lyrics; the parser reads
    /// its text so the caller can fall back to plain lyrics instead.
    var sawTiming = false

    /// The kind of span currently open. A backing-vocal container holds the word
    /// spans of one backing phrase; word spans are the leaves that carry text.
    private enum SpanKind {
        case leadWord
        case backgroundWord
        case backgroundContainer
    }

    private var spanStack: [SpanKind] = []

    private var lineBeginMs: Int?
    private var lineEndMs: Int?
    private var inLine = false

    // Lead vocal.
    private var leadPlainText = ""
    private var leadSpanJoinedText = ""
    private var hasLeadSpan = false
    private var leadWords: [TimedWord] = []
    private var leadSpansSeen = 0
    private var leadPendingSpaceBetweenSpans = false

    // Backing vocal.
    private var backgroundJoinedText = ""
    private var backgroundWords: [TimedWord] = []
    private var backgroundSpansSeen = 0
    private var backgroundPendingSpaceBetweenSpans = false

    // The word span currently being read.
    private var spanText = ""
    private var spanBeginMs: Int?
    /// Whether the span being closed begins a new word (so it needs a leading
    /// space unless it already has one).
    private var needsLeadingSpace = false
    /// Nonzero while inside a skipped subtree (translation/romanization spans).
    private var skippedSpanDepth = 0

    private var isInsideWordSpan: Bool {
        switch self.spanStack.last {
        case .leadWord, .backgroundWord: true
        default: false
        }
    }

    private var isInsideBackgroundContainer: Bool {
        self.spanStack.contains(.backgroundContainer)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName.lowercased() {
        case "p":
            self.beginLine()
            self.lineBeginMs = Self.timeToMs(attributeDict["begin"])
            self.lineEndMs = Self.timeToMs(attributeDict["end"])
            if self.lineBeginMs != nil || self.lineEndMs != nil {
                self.sawTiming = true
            }
        case "span":
            if self.skippedSpanDepth > 0 {
                self.skippedSpanDepth += 1
                return
            }
            let role = Self.attribute(named: "role", in: attributeDict)
            if role == "x-translation" || role == "x-roman" {
                self.skippedSpanDepth = 1
                return
            }
            if role == "x-bg" {
                // The container itself carries no text; its child spans do.
                self.spanStack.append(.backgroundContainer)
                self.backgroundPendingSpaceBetweenSpans = false
                return
            }

            let isBackground = self.isInsideBackgroundContainer
            self.spanStack.append(isBackground ? .backgroundWord : .leadWord)
            self.spanText = ""
            self.spanBeginMs = Self.timeToMs(attributeDict["begin"])
            if self.spanBeginMs != nil {
                self.sawTiming = true
            }
            if isBackground {
                // Whitespace between the previous backing span and this one marks a
                // word boundary; syllable continuations have none.
                self.needsLeadingSpace = self.backgroundPendingSpaceBetweenSpans && self.backgroundSpansSeen > 0
                self.backgroundPendingSpaceBetweenSpans = false
            } else {
                self.hasLeadSpan = true
                self.needsLeadingSpace = self.leadPendingSpaceBetweenSpans && self.leadSpansSeen > 0
                self.leadPendingSpaceBetweenSpans = false
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard self.skippedSpanDepth == 0 else { return }

        if self.isInsideWordSpan {
            self.spanText += string
            return
        }
        guard self.inLine else { return }

        if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Whitespace-only text between spans marks a word boundary rather than
            // contributing to the line text.
            if self.isInsideBackgroundContainer {
                self.backgroundPendingSpaceBetweenSpans = true
            } else {
                self.leadPendingSpaceBetweenSpans = true
            }
        } else if self.isInsideBackgroundContainer {
            self.backgroundJoinedText += string
        } else {
            self.leadPlainText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName.lowercased() {
        case "span":
            if self.skippedSpanDepth > 0 {
                self.skippedSpanDepth -= 1
                return
            }
            guard let kind = self.spanStack.popLast() else { return }
            guard kind != .backgroundContainer else { return }

            var text = self.spanText
            if self.needsLeadingSpace, !text.hasPrefix(" "), !text.hasPrefix("\t") {
                text = " " + text
            }
            let isBackground = kind == .backgroundWord
            if let begin = self.spanBeginMs,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                let word = TimedWord(timeInMs: begin, word: text, isBackground: isBackground)
                if isBackground {
                    self.backgroundWords.append(word)
                } else {
                    self.leadWords.append(word)
                }
            }
            if isBackground {
                self.backgroundJoinedText += text
                self.backgroundSpansSeen += 1
            } else {
                self.leadSpanJoinedText += text
                self.leadSpansSeen += 1
            }
            self.spanText = ""
            self.spanBeginMs = nil
            self.needsLeadingSpace = false
        case "p":
            self.endLine()
        default:
            break
        }
    }

    // MARK: - Line state

    private func beginLine() {
        self.inLine = true
        self.spanStack.removeAll()
        // The paragraph's own window is not cleared here: `didStartElement` assigns both from
        // the new `<p>`'s attributes, which writes `nil` when it declares neither. A `<p>`
        // therefore never inherits the one before it — see
        // `SyncedLyricsPauseGapTests.untimedParagraphDoesNotInherit`, which is what holds that.
        self.leadPlainText = ""
        self.leadSpanJoinedText = ""
        self.hasLeadSpan = false
        self.leadWords.removeAll()
        self.leadSpansSeen = 0
        self.leadPendingSpaceBetweenSpans = false
        self.backgroundJoinedText = ""
        self.backgroundWords.removeAll()
        self.backgroundSpansSeen = 0
        self.backgroundPendingSpaceBetweenSpans = false
        self.spanText = ""
        self.spanBeginMs = nil
        self.needsLeadingSpace = false
        self.skippedSpanDepth = 0
    }

    private func endLine() {
        guard self.inLine else { return }
        self.inLine = false
        self.skippedSpanDepth = 0
        self.spanStack.removeAll()

        // When a line has word spans, its text comes only from the spans;
        // inter-span formatting whitespace is ignored.
        let leadText = (self.hasLeadSpan ? self.leadSpanJoinedText : self.leadPlainText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let backgroundText = self.backgroundJoinedText.trimmingCharacters(in: .whitespacesAndNewlines)

        let leadWords = self.leadWords.isEmpty ? nil : self.leadWords
        let backgroundWords = self.backgroundWords.isEmpty ? nil : self.backgroundWords
        self.leadWords.removeAll()
        self.backgroundWords.removeAll()

        let begin = self.lineBeginMs
            ?? leadWords?.first?.timeInMs
            ?? backgroundWords?.first?.timeInMs
            ?? 0
        let end = self.lineEndMs ?? (begin + 4_000)

        // An empty `<p begin end>` is an instrumental interlude spelled out rather than
        // left to the timeline, and the renderer turns such a line into the pause dots. It
        // is the *rare* spelling: the Apple Music TTML these providers serve has no empty
        // paragraph anywhere in it and leaves every interlude as a gap between two
        // contiguous paragraphs, which `SyncedLyrics.withPauseInterludes` turns into rows
        // of its own. Keeping this case means a document that does spell one out gets a
        // row even if nothing about its neighbours looks like a gap. A paragraph with no
        // declared window at all cannot be placed on the timeline and is still dropped.
        guard !leadText.isEmpty || !backgroundText.isEmpty else {
            guard self.lineBeginMs != nil || self.lineEndMs != nil else { return }
            self.lines.append(SyncedLyricLine(
                timeInMs: begin,
                duration: max(1, end - begin),
                text: "",
                words: nil,
                backgroundWords: nil
            ))
            return
        }

        self.lines.append(SyncedLyricLine(
            timeInMs: begin,
            duration: max(1, end - begin),
            text: leadText,
            words: leadWords,
            backgroundWords: backgroundWords
        ))
    }

    /// Finds a namespaced TTML metadata attribute (e.g. `ttm:role`) regardless
    /// of the prefix the document chose to use.
    private static func attribute(named localName: String, in attributes: [String: String]) -> String? {
        if let direct = attributes[localName] {
            return direct
        }
        for (key, value) in attributes {
            if key == localName || key.hasSuffix(":\(localName)") {
                return value
            }
        }
        return nil
    }

    /// Parses TTML times: `HH:MM:SS.mmm`, `MM:SS.mmm`, or `SS.mmm`.
    private static func timeToMs(_ value: String?) -> Int? {
        guard let value, !value.isEmpty else { return nil }
        let parts = value.split(separator: ":")
        guard let last = parts.last, let seconds = Double(last) else { return nil }
        var total = seconds
        var multiplier = 1.0
        for part in parts.dropLast().reversed() {
            multiplier *= 60
            total += (Double(part) ?? 0) * multiplier
        }
        return Int(total * 1000)
    }
}
