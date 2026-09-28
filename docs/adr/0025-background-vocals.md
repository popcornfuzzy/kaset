# ADR-0025: Background Vocals in the Shared Lyrics Model

## Status

Accepted

## Context

Apple Music TTML encodes backing vocals as a nested
`<span ttm:role="x-bg">` inside the line's `<p>`, holding its own word spans.
`TTMLParser` treated every span with a `begin` as part of the lead line, so a
backing phrase was appended to the lead text and words. Two things went wrong:

- The backing text ran into the lead text — the gap between the lead's last
  span and the backing container was consumed by the container and never became
  a word boundary, producing text like `feelingsThat's`.
- The backing words were interleaved into `line.words` with onsets that overlap
  the lead, so the karaoke fill model — which assumes each word's window ends at
  the next word's onset — folded a full line's timing into a sliver and then
  swept backwards.

The same information reaches Kaset from Paxsenix's structured `content` array,
which flags a whole content line with `background: true`.

## Decision

Model backing vocals in the shared lyrics types so every provider and format can
express them, and keep them out of the lead line:

- `TimedWord` gains `isBackground`.
- `SyncedLyricLine` gains `backgroundWords` (and a derived `backgroundText`),
  kept apart from `words` and from `text`.
- `TTMLParser` routes spans inside a `ttm:role="x-bg"` container into
  `backgroundWords`, with the same inter-span whitespace rule the lead words use
  so the backing phrase is spaced correctly.
- `PaxsenixProvider` routes content lines flagged `background` into
  `backgroundWords`.
- `SyncedLyrics.pauseInterlude` no longer treats a line whose only content is
  backing vocals as an instrumental pause.
- Both renderers show backing vocals on their own dimmed, slightly smaller row
  under the lead line, animated with the **same per-character karaoke wipe** as
  the lead (see *Amendment* below).

`TimedWord` and `SyncedLyricLine` decode the new fields with `decodeIfPresent`,
so older cache files still decode. They would decode as *stale*, though — the
glued text is already in the payload — so `LyricsCacheStore` now stamps each
per-song file with a `schemaVersion` and treats a file written by an older one as
a miss. That is how the fix reaches every song already played without the user
clearing the cache by hand.

## Amendment: animated backing vocals

The static backing row shipped first, but accompaniment that does not fill while
the line fills reads as broken text. Backing vocals now run the same karaoke
machinery as the lead:

- `KaraokeFillModel.backgroundWords(for:)` derives fill windows from
  `backgroundWords` exactly as `words(for:)` does from `words`. The backing vocal
  overlaps the lead in time and carries its own onsets, so synchrony with the
  lead is simply both lines being rendered from the same display-clock position
  inside the one `KaraokeTimeSource` — no second clock, no interpolation between
  the two.
- `SyncedLyricLine.backingVocalLine` reshapes the line so `KaraokeLineLayout` —
  which reads `words` — can measure the backing words with the machinery it
  already has. The synthetic line keeps the original `id`, so layout caching and
  SwiftUI identity stay per row.
- `KaraokeLayoutCache` is keyed by (line id, font size, lead-or-backing) instead
  of line id alone: one row now measures a lead layout and a smaller backing
  layout side by side, and keying by the line alone would clear on every
  alternating lookup, re-measuring one of the two every frame. The kind is part
  of the key rather than implied by the size, because the two are different text
  — a size that happened to coincide would otherwise draw one of them with the
  other's words.
- `settleBoundaryMs` now also counts the backing ramps. A held backing note can
  outlast the lead's last word; without this the row would leave the display
  clock — and freeze the backing wipe mid-word — while the accompaniment was
  still filling. The backing still does not drive `highlightIndex`: which line is
  being sung is decided by the lead.
- The backing row differs from the lead only in color, opacity and size (sidebar
  14 pt `.secondary`, fullscreen 36 pt × 0.62 at white 55 %), with the same
  emphasis (glow and per-character lift) the lead gets.

The static `LyricsBackgroundVocalsView` was removed; nothing outside the two
lyrics renderers ever drew backing vocals.

Model and parsing are unchanged by the amendment, so the lyrics cache schema
version is untouched: a cached backing-vocal payload animates identically to a
freshly parsed one.

## Amendment: pause dots in word-synced lyrics

The pause-dots interlude only ever showed for line-synced lyrics. The renderer
was not the problem — it routes any empty line to the dots in either mode. The
problem is that **word-synced sources never emit an empty line**, and the first
attempt at this fix assumed they did.

That attempt added "keep an empty timed entry" to `TTMLParser` and
`PaxsenixProvider` (`parseContent` and `parseELRC`), on the theory that a
word-synced source marks an interlude with a `<p begin end>` carrying no spans.
Reading a real payload disproves it: Apple Music TTML writes its paragraphs
**contiguous within a line and absent across an interlude** — a played-and-parsed
Autobahn library (`ZJ5VMKDm1Vs`) has 52 paragraphs, 21 gaps of ≥ 600 ms between
them, and **not one empty paragraph**. Every word-synced song in a 41-song real
cache is the same. So the parser change added no rows, fixed no dots, and could
not have caused the performance regression it was blamed for: it was a no-op.

The interlude is the **gap in the timeline** — the previous line's end to the
next line's start — and that is now what the dots are derived from, in
`SyncedLyrics.withPauseInterludes(minimumGapMs:)`. It is applied once, where a
result is installed (`SyncedLyricsService.apply`), rather than in the parsers or
the renderers:

- Not in the parsers, because the gap is a property of the sheet and not of any
  one format. A word-synced TTML and a line-synced one both leave their
  interludes implicit, and providers re-encode each other's documents freely.
- Not in the renderers, because the dots need a **line**. Every index the
  display reads — the highlight, the scroll target, the row statuses — has to
  count the same rows, so the rows have to exist in the sheet before the sheet
  is drawn.

The synthesized row spans the gap exactly. A gap whose far side is already a
silent line is left alone: that line is the row the dots render on, and adding
another would put two rows in one stretch of silence. The cached result is still
what the provider returned, so the rows are not written to disk twice over and a
cache written before this existed gets them too.

The empty-entry retention in the parsers is kept — it is the right reading of an
explicitly empty paragraph, and an ELRC or `content` entry is the only place a
gap between two of its neighbours can be observed at all — but it is no longer
what the dots depend on. For that path to work, a `content` entry's duration has
to run to the next entry that actually carries a timestamp: measuring it against
an untimed neighbour collapsed it to a single millisecond, which is both too
short to be a pause row and too short for the highlight to show at all. Because it does change what is parsed,
`LyricsCacheStore.schemaVersion` stays at 3.

## Consequences

- Backing vocals are spaced correctly and no longer drag the lead line's karaoke
  timing backwards.
- The information is available to every provider that can express it, not only
  Unison (whose TTML, BetterLyrics' and Paxsenix's all route through the same
  parser).
- Backing vocals animate with the same per-character wipe as the lead line,
  synchronized through the shared display clock, while staying visually
  subordinate (smaller, dimmer, no effect on the highlight).
- The per-line credit placement is unchanged by this ADR; see
  [ADR-0024](0024-unison-provider.md) for attribution.
- Cache invalidation is now coupled to the schema version: any future change to
  how lyrics are parsed must bump `LyricsCacheStore.schemaVersion`, or stale
  text will keep being served for already-played songs. (Currently at 3: the
  backing-vocal fix, then the retention of instrumental-gap lines.)
- Pause dots no longer depend on any provider writing an empty line: the
  interlude is read from the timeline itself, so line-synced and word-synced
  sheets behave the same way, and a source that spells its interludes out
  explicitly still gets exactly one row for each.
