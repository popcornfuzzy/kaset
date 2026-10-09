import Foundation

// MARK: - LyricsBackingParentheses

/// Backing vocals a source wrote as a phrase in parentheses, moved onto the line's backing
/// row.
///
/// Parentheses are how a lyrics source spells a backing vocal when it has no field for one.
/// Apple Music keeps the marker for its TTML — the phrase sits *inside* an
/// `ttm:role="x-bg"` span, parentheses and all, so `dancin' on my own` is followed by a
/// backing span reading `(Dancin' … own)`, and an ad-lib line is a backing span reading
/// `(Yes)`. A provider that parses that markup faithfully therefore still hands the display
/// a backing row printing its own parentheses. The line-synced sources mark nothing at all
/// and put the phrase in the words of the line itself — `You smart (you smart) 누가 You are`
/// — or give it a line of nothing else: `(Oh-oh-oh-oh-oh)`.
///
/// Kaset has a place for a backing vocal — `SyncedLyricLine.backgroundWords` when the source
/// timed the phrase as words, `SyncedLyricLine.untimedBackgroundText` when it did not, both
/// drawn on the dimmed row under the lead — so a parenthesis is not something to display: it is
/// the instruction. The phrase belongs on the backing row, without the parentheses. A phrase
/// that names part of the sheet instead ("(Chorus)", "(x2)") is not a vocal at all and is
/// dropped, and a line left with nothing at all after both moves loses the line.
///
/// Applied once where a result is shaped for the display (see `SyncedLyricsService.apply`),
/// never per frame, so the rows are part of the sheet afterwards and every index the display
/// works with counts them. It runs in the same place as `SyncedLyrics.withPauseInterludes`
/// and before it: a line that keeps only a backing row has something to sing and must not be
/// read as an interlude.
enum LyricsBackingParentheses {
    /// A line's text once its parenthesized phrases are read out of it.
    struct Split {
        /// The lead lyric: the text with every phrase taken out of it.
        let lead: String
        /// The backing phrases, in the order they are sung.
        let backing: [String]
        /// Whether the text carried a parenthesis the pass acted on.
        let sawPhrase: Bool
    }

    /// A backing phrase read out of a word-timed line, with the onset of the word that
    /// opened it.
    private struct Phrase {
        let text: String
        let timeInMs: Int
    }

    static let opening: Set<Character> = ["(", "（"]
    static let closing: Set<Character> = [")", "）"]

    /// Phrases that name part of the sheet rather than a vocal. They are the form of the
    /// lyrics — a source writing `[Chorus]` in another notation — and singing them on the
    /// backing row would be worse than not showing them.
    private static let labels: Set<String> = [
        "chorus", "pre chorus", "post chorus", "verse", "bridge", "refrain", "hook",
        "intro", "outro", "instrumental", "interlude", "break", "repeat", "tag",
        "ad lib", "ad libs", "adlib", "adlibs", "backing vocals", "harmonies",
    ]

    // MARK: - Reading a phrase out of text

    /// Reads the parenthesized phrases out of a line's text.
    ///
    /// An opener the source never closed is not a phrase — it did not finish what it
    /// started — so its text stays in the lead lyric rather than being dropped from the
    /// sheet.
    static func split(_ text: String) -> Split {
        var lead = ""
        var backing: [String] = []
        var phrase = ""
        var opener: Character?
        var depth = 0
        var sawPhrase = false

        for character in text {
            if Self.opening.contains(character) {
                depth += 1
                sawPhrase = true
                if depth == 1 { opener = character } else { phrase.append(character) }
            } else if Self.closing.contains(character), depth > 0 {
                depth -= 1
                if depth == 0 {
                    Self.append(phrase, to: &backing)
                    phrase = ""
                } else {
                    phrase.append(character)
                }
            } else if depth > 0 {
                phrase.append(character)
            } else {
                lead.append(character)
            }
        }

        if depth > 0 {
            lead.append(opener ?? "(")
            lead.append(phrase)
        }

        return Split(lead: sawPhrase ? Self.respaced(lead) : lead, backing: backing, sawPhrase: sawPhrase)
    }

    /// Whether a phrase names part of the sheet — `(Chorus)`, `(Verse 2)`, `(x2)` — rather
    /// than a vocal.
    static func isLabel(_ phrase: String) -> Bool {
        // A repeat count: "(x2)", "(2x)", "(4)".
        if phrase.range(of: #"^\s*x?\s*\d+\s*x?\s*$"#, options: .regularExpression) != nil { return true }

        let label = phrase
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            // "Chorus 2" and "Verse 1" are the same label as "Chorus" and "Verse".
            .replacingOccurrences(of: #"\s*\d+\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return Self.labels.contains(label)
    }

    /// Backing text that already sits on the backing row, with the parentheses dropped:
    /// `(Yes)` reads `Yes` there, and `(Dancin'` reads `Dancin'`.
    static func unparenthesized(_ text: String) -> String {
        var stripped = ""
        for character in text where !Self.opening.contains(character) && !Self.closing.contains(character) {
            stripped.append(character)
        }
        return stripped
    }

    /// Taking a phrase out of the middle of a line leaves the spaces that held it apart
    /// (`So sorry  I'm not sorry`).
    private static func respaced(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Keeps a phrase the pass can use: an empty one and a section label are both dropped.
    private static func backingPhrase(_ phrase: String) -> String? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !Self.isLabel(trimmed) else { return nil }
        return trimmed
    }

    private static func append(_ phrase: String, to backing: inout [String]) {
        guard let phrase = Self.backingPhrase(phrase) else { return }
        backing.append(phrase)
    }

    // MARK: - Reading a phrase out of timed words

    /// Reads the parenthesized phrases out of a word-timed line's words.
    ///
    /// The scan carries its own depth across the whole word list, because a phrase can open
    /// in one word and close in another (`(you` … `smart)`): reading each word on its own
    /// would see two half-phrases and put neither on the backing row. Each phrase keeps the
    /// onset of the word that opened it, so a converted phrase still fills with the karaoke
    /// wipe where it is sung. A word is only ever cut, never re-invented: one the phrase did
    /// not touch keeps its own text and its own spacing exactly.
    private static func splitWords(_ words: [TimedWord]) -> (lead: [TimedWord], phrases: [Phrase], sawPhrase: Bool) {
        var lead: [TimedWord] = []
        var phrases: [Phrase] = []
        var phrase = ""
        var phraseStart: Int?
        // The words a phrase that is still open has taken, and how much lead text was on the
        // line when it opened, so an unclosed one can be handed back intact.
        var consumed: [TimedWord] = []
        var leadCountAtPhraseStart = 0
        var depth = 0
        var sawPhrase = false

        for word in words {
            var text = ""
            var touched = false
            var openedHere = false
            for character in word.word {
                if Self.opening.contains(character) {
                    depth += 1
                    sawPhrase = true
                    touched = true
                    if depth == 1 {
                        phraseStart = word.timeInMs
                        consumed = []
                        leadCountAtPhraseStart = lead.count
                        openedHere = true
                    } else {
                        phrase.append(character)
                    }
                } else if Self.closing.contains(character), depth > 0 {
                    depth -= 1
                    touched = true
                    if depth == 0 {
                        if let phraseText = Self.backingPhrase(phrase) {
                            phrases.append(Phrase(text: phraseText, timeInMs: phraseStart ?? word.timeInMs))
                        }
                        phrase = ""
                        phraseStart = nil
                        consumed = []
                    } else {
                        phrase.append(character)
                    }
                } else if depth > 0 {
                    phrase.append(character)
                    touched = true
                } else {
                    text.append(character)
                }
            }

            if touched, openedHere {
                consumed.append(word)
            } else if touched, depth > 0, !consumed.isEmpty {
                consumed.append(word)
            }

            guard touched else {
                // The phrase did not touch this word: it goes on the lead line untouched, so
                // its spacing, its syllable continuation and its own timings all survive.
                lead.append(word)
                continue
            }

            // A word the phrase did not take whole keeps what is left of it ("lead(bg)tail"
            // leaves "lead" and "tail"), timed where the word itself was, and separated from
            // the text around it where the phrase used to sit.
            let residue = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !residue.isEmpty else { continue }
            let separated = text.hasPrefix(" ") || text.hasPrefix("\t") || lead.isEmpty
            lead.append(TimedWord(timeInMs: word.timeInMs, word: separated ? text : " " + text))
        }

        if depth > 0 {
            // The phrase never closed: the words it took are lead words after all, and the
            // lead text they left behind goes — each word is restored whole and once.
            lead.removeLast(lead.count - leadCountAtPhraseStart)
            lead.append(contentsOf: consumed)
        }

        return (lead, phrases, sawPhrase)
    }

    // MARK: - Lines

    /// The line with its parenthesized backing vocals on its backing row, or `nil` when the
    /// line carried nothing else — it was a section label (`(Chorus)`) and is not a lyric.
    static func converted(_ line: SyncedLyricLine) -> SyncedLyricLine? {
        // Backing text the provider already modelled: the parentheses were decoration on a
        // row that already reads as accompaniment.
        var backing = (line.backgroundWords ?? []).compactMap { word -> TimedWord? in
            let text = Self.unparenthesized(word.word)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TimedWord(timeInMs: word.timeInMs, word: text, isBackground: true)
        }
        // How many backing words the row already had, so a converted phrase knows whether it
        // needs the space that separates it from what came before.
        let declaredBacking = backing.count

        // Phrases the source never timed, in the order it wrote them. A row that already has
        // one keeps it: the pass is applied where a result is shown, and a sheet that reaches
        // it twice must not lose text the second time.
        var untimedPhrases = line.untimedBackgroundText.map { [$0] } ?? []

        var leadWords = line.words
        var leadText = line.text
        var sawPhrase = false

        if let words = line.words, !words.isEmpty {
            let fromWords = Self.splitWords(words)
            if fromWords.sawPhrase {
                sawPhrase = true
                leadWords = fromWords.lead.isEmpty ? nil : fromWords.lead
                // The line's text is its words, so it is rebuilt from the ones that remain
                // rather than cleaned on its own: karaoke draws the words, and the two must
                // never disagree about what the line says.
                leadText = fromWords.lead.map(\.word).joined()
                backing += Self.backingWords(from: fromWords.phrases, after: declaredBacking)
            } else if let fromText = Self.textPhrases(of: line.text) {
                // An enhanced LRC can write a phrase it never timed as a word. Nothing about
                // when its words are sung is known, so the phrase is given no onsets: the words
                // are left alone, and the phrase joins the row's untimed backing text.
                sawPhrase = true
                leadText = fromText.lead
                untimedPhrases += fromText.phrases
            }
        } else if let fromText = Self.textPhrases(of: line.text) {
            sawPhrase = true
            leadText = fromText.lead
            untimedPhrases += fromText.phrases
        }

        let trimmedLead = leadText.trimmingCharacters(in: .whitespacesAndNewlines)
        let untimedBacking = untimedPhrases.isEmpty ? nil : untimedPhrases.joined(separator: " ")
        let hasBacking = !backing.isEmpty || untimedBacking != nil
        // A line that is silent to begin with is an interlude, not an empty result: only a
        // line that had something to say and lost all of it to a label is dropped.
        let hadContent = !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(line.words ?? []).isEmpty
            || !(line.backgroundWords ?? []).isEmpty
            || !(line.untimedBackgroundText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if trimmedLead.isEmpty, !hasBacking, hadContent, sawPhrase { return nil }

        return SyncedLyricLine(
            timeInMs: line.timeInMs,
            duration: line.duration,
            text: trimmedLead,
            words: leadWords,
            backgroundWords: backing.isEmpty ? nil : backing,
            untimedBackgroundText: untimedBacking,
            id: line.id
        )
    }

    /// The line's text read as a lead lyric plus the phrases taken out of it, or `nil` when
    /// it carried no parenthesis at all.
    ///
    /// A parenthesis that yields no phrase — a section label — still counts as read: the text
    /// is the cleaned one, and a line left with nothing of it goes.
    private static func textPhrases(of text: String) -> (lead: String, phrases: [String])? {
        let split = Self.split(text)
        guard split.sawPhrase else { return nil }
        return (split.lead, split.backing)
    }

    /// Phrases read out of the words, as the backing row's own words. Each after the row's
    /// first word carries the space that separates it — the same rule the providers' own
    /// backing words follow.
    ///
    /// Only a phrase read **out of the words** gets here: those words have onsets, so the phrase
    /// has one, and the karaoke wipe it is drawn with is its own. A phrase read out of the line's
    /// *text* has no onset and never becomes a `TimedWord` — it goes to the row's untimed
    /// backing text instead.
    private static func backingWords(from phrases: [Phrase], after preceding: Int) -> [TimedWord] {
        phrases.enumerated().map { index, phrase in
            let needsSpace = preceding + index > 0
            return TimedWord(
                timeInMs: phrase.timeInMs,
                word: needsSpace ? " " + phrase.text : phrase.text,
                isBackground: true
            )
        }
    }

    // MARK: - Sheets

    static func converted(_ lyrics: SyncedLyrics) -> SyncedLyrics {
        SyncedLyrics(
            lines: lyrics.lines.compactMap(Self.converted),
            source: lyrics.source,
            attribution: lyrics.attribution
        )
    }

    /// The plain text with every parenthesized backing phrase taken out of it.
    ///
    /// A flat sheet has no backing row to move a phrase onto, so the two ways to answer are
    /// the phrase still in the words or the phrase gone. What a listener reads is the lead
    /// lyric, so the phrase goes, and a line that was nothing but a phrase loses its line.
    static func removingParenthesizedBackingVocals(from lyrics: Lyrics) -> Lyrics {
        let lines = lyrics.text.components(separatedBy: "\n").compactMap { line -> String? in
            let split = Self.split(line)
            // A line with no parenthesis at all is untouched, so the sheet keeps whatever
            // spacing its source gave it.
            guard split.sawPhrase else { return line }
            return split.lead.isEmpty ? nil : split.lead
        }
        return Lyrics(text: lines.joined(separator: "\n"), source: lyrics.source, attribution: lyrics.attribution)
    }
}

// MARK: - Model entry points

extension SyncedLyrics {
    /// The sheet with every parenthesized backing vocal moved onto its line's backing row.
    func convertingParenthesizedBackingVocals() -> SyncedLyrics {
        LyricsBackingParentheses.converted(self)
    }
}

extension Lyrics {
    /// The plain text with every parenthesized backing vocal taken out of it.
    func removingParenthesizedBackingVocals() -> Lyrics {
        LyricsBackingParentheses.removingParenthesizedBackingVocals(from: self)
    }
}
