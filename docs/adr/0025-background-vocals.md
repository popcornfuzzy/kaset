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
  under the lead line; the lead line's karaoke wipe is untouched.

`TimedWord` and `SyncedLyricLine` decode the new fields with `decodeIfPresent`,
so older cache files still decode. They would decode as *stale*, though — the
glued text is already in the payload — so `LyricsCacheStore` now stamps each
per-song file with a `schemaVersion` and treats a file written by an older one as
a miss. That is how the fix reaches every song already played without the user
clearing the cache by hand.

## Consequences

- Backing vocals are spaced correctly and no longer drag the lead line's karaoke
  timing backwards.
- The information is available to every provider that can express it, not only
  Unison (whose TTML, BetterLyrics' and Paxsenix's all route through the same
  parser).
- Backing vocals are drawn as a static dimmed row rather than a second karaoke
  wipe: the fill model assumes one monotonic word sequence per line and is left
  undisturbed.
- The per-line credit placement is unchanged by this ADR; see
  [ADR-0024](0024-unison-provider.md) for attribution.
- Cache invalidation is now coupled to the schema version: any future change to
  how lyrics are parsed must bump `LyricsCacheStore.schemaVersion`, or stale
  text will keep being served for already-played songs.
