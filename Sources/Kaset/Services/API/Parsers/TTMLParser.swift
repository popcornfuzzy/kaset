import Foundation

// MARK: - TTMLParser

/// Parses Apple Music TTML (the `itunes:timing="Word"` format served by both
/// the Paxsenix and BetterLyrics integrations) into Kaset's `SyncedLyrics`.
///
/// Each `<p>` becomes a line; its `<span>` children become per-word timings.
/// Word spacing comes from the source — whitespace between spans marks a word
/// boundary, while syllable continuations have no inter-span whitespace and are
/// glued together.
///
/// Spans carrying a translation or romanization role (`ttm:role="x-translation"`
/// / `"x-roman"`) are skipped: they restate the line in another script and would
/// otherwise be appended as extra (out-of-sync) words.
enum TTMLParser {
    static func parse(_ raw: String, source: String) -> SyncedLyrics? {
        guard let data = raw.data(using: .utf8) else { return nil }
        let delegate = TTMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), !delegate.lines.isEmpty else { return nil }
        return SyncedLyrics(lines: delegate.lines, source: source)
    }
}

// MARK: - TTMLParserDelegate

private final class TTMLParserDelegate: NSObject, XMLParserDelegate {
    var lines: [SyncedLyricLine] = []

    private var lineBeginMs: Int?
    private var lineEndMs: Int?
    private var plainText = ""
    private var spanJoinedText = ""
    private var hasSpan = false
    private var pendingWords: [TimedWord] = []
    private var inLine = false
    private var inSpan = false
    private var spanBeginMs: Int?
    private var spanText = ""
    private var spansSeen = 0
    /// Set when whitespace-only text sits between two spans — Apple's Word
    /// timing format marks word boundaries that way. Syllable continuations
    /// have no inter-span whitespace and are glued together.
    private var pendingSpaceBetweenSpans = false
    /// Whether the span currently being closed begins a new word (so it needs
    /// a leading space unless it already has one).
    private var needsLeadingSpace = false
    /// Nonzero while inside a skipped subtree (translation/romanization spans).
    private var skippedSpanDepth = 0

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName.lowercased() {
        case "p":
            inLine = true
            plainText = ""
            spanJoinedText = ""
            hasSpan = false
            pendingWords.removeAll()
            spansSeen = 0
            pendingSpaceBetweenSpans = false
            needsLeadingSpace = false
            skippedSpanDepth = 0
            lineBeginMs = Self.timeToMs(attributeDict["begin"])
            lineEndMs = Self.timeToMs(attributeDict["end"])
        case "span":
            if skippedSpanDepth > 0 {
                skippedSpanDepth += 1
                return
            }
            if let role = Self.attribute(named: "role", in: attributeDict),
               role == "x-translation" || role == "x-roman"
            {
                skippedSpanDepth = 1
                return
            }
            hasSpan = true
            inSpan = true
            spanText = ""
            spanBeginMs = Self.timeToMs(attributeDict["begin"])
            // Whitespace between the previous span and this one marks a word
            // boundary; syllable continuations have no inter-span whitespace.
            needsLeadingSpace = pendingSpaceBetweenSpans && spansSeen > 0
            pendingSpaceBetweenSpans = false
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skippedSpanDepth == 0 else { return }
        if inSpan {
            spanText += string
        } else if inLine {
            if string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Whitespace-only text between spans (or around them) marks a
                // word boundary rather than contributing to the line text.
                pendingSpaceBetweenSpans = true
            } else {
                plainText += string
            }
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
            if skippedSpanDepth > 0 {
                skippedSpanDepth -= 1
                return
            }
            var text = spanText
            if needsLeadingSpace, !text.hasPrefix(" "), !text.hasPrefix("\t") {
                text = " " + text
            }
            if let begin = spanBeginMs,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                pendingWords.append(TimedWord(timeInMs: begin, word: text))
            }
            spanJoinedText += text
            spansSeen += 1
            inSpan = false
            spanBeginMs = nil
            needsLeadingSpace = false
        case "p":
            guard inLine else { break }
            inLine = false
            skippedSpanDepth = 0
            // When a line has word spans, its text comes only from the spans;
            // inter-span formatting whitespace is ignored.
            let text = (hasSpan ? spanJoinedText : plainText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                pendingWords.removeAll()
                return
            }
            let begin = lineBeginMs ?? (pendingWords.first?.timeInMs ?? 0)
            let end = lineEndMs ?? (begin + 4_000)
            // Word spacing comes from the source (inter-span whitespace and
            // span text) — never inject spaces between syllable parts.
            let words = pendingWords.isEmpty ? nil : pendingWords
            lines.append(SyncedLyricLine(timeInMs: begin, duration: max(1, end - begin), text: text, words: words))
            pendingWords.removeAll()
        default:
            break
        }
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
