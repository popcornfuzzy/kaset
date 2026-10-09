# ADR-0032: Two Singers in Synced Lyrics (Opposite Turns)

## Status

Accepted

## Context

A duet's lyrics are not one voice. Apple Music draws the second singer's lines against the
other edge of the lyrics view, so a verse by one singer sits on the left and the answering
verse by the other sits on the right; the turns are what makes a duet readable as a
conversation.

The information is in the payload, and Kaset was discarding it:

- **Apple Music TTML** attributes each paragraph to an **agent** and declares those agents in
  the document's metadata. Apple's own beat-by-beat example for *Dancing With A Stranger* is
  the shape:

  ```xml
  <head><metadata>
    <ttm:agent type="person" xml:id="v1"><ttm:name type="full">Sam Smith</ttm:name></ttm:agent>
    <ttm:agent type="person" xml:id="v2"><ttm:name type="full">Normani</ttm:name></ttm:agent>
    <ttm:agent type="group" xml:id="v3"/>
  </metadata></head>
  <body>
    <div itunes:song-part="Verse">
      <p begin="00:07.621" end="00:10.267" ttm:agent="v1">…</p>
      <p begin="00:12.395" end="00:15.728" ttm:agent="v2">…</p>
      <p begin="00:17.141" end="00:20.976" ttm:agent="v3">…</p>
  ```

  `TTMLParser` ignored `ttm:agent` entirely, so every line arrived unattributed. The live
  payloads have the same shape at the same place: the single-agent documents the providers
  serve declare `<ttm:agent type="person" xml:id="v1"/>` and repeat `ttm:agent="v1"` on every
  paragraph.
- **Paxsenix** says it structurally: a content line carries an `oppositeTurn` flag, and its
  ELRC writes the singer as a marker in braces — `[00:12.395]{v2}I wasn't even going out
  tonight`. The flag was decoded but unused, and the ELRC markers were being stripped by
  `stripAgents` along with everything else in braces, taking the singer with the punctuation.

## Decision

Model the turn on the line and resolve it where the source is read, because only the source
knows which agent leads:

- `SyncedLyricLine.isOppositeTurn` (default `false`, written to the cache only when true) — the
  line belongs to a singer other than the sheet's lead. `SyncedLyrics.hasOppositeTurns` answers
  whether the sheet is a duet at all.
- **`TTMLParser`** reads the declaration order and types from the metadata
  (`<ttm:agent type="person" xml:id="v1">`) and the paragraph's own `ttm:agent`, and resolves
  the line:
  - The **lead** is the first agent the metadata declares as a `person`. A document that
    declares no agents at all is led by the first agent it puts on a paragraph, so a
    hand-written duet still alternates instead of pushing everything to one side.
  - A line whose agent is not the lead is an opposite turn — **unless** the agent is declared
    `type="group"`, which is the document's own word for both singers together: a group is not
    one singer taking over from the other, so its lines stay where the lead's are.
  - A line with no agent is not a turn.
  - `ttm:agent` on the enclosing `<div>` is inherited by its paragraphs (TTML metadata
    attributes inherit) and a `<p>` that declares its own wins.
  - Element and attribute names are matched on their **local** name, so `ttm:agent` reads the
    same whether the document prefixes it or relies on the default namespace.
- **`PaxsenixProvider`** maps its own `oppositeTurn` flag onto the same field, and reads the
  ELRC voice marker before stripping braces: the first `{vN}` a document writes leads, and a
  line that names another voice is a turn. Only a marker shaped like Apple's agent ids counts
  — the format writes other things in braces, a backing-vocal marker among them, and those are
  not a second singer.
- **The display** draws a turn against the trailing edge, in both the panel and the fullscreen
  player: the row's frame and scale anchor move to the trailing side (`SyncedLineView`,
  `FullscreenSyncedLineView`), and the karaoke line itself takes `isTrailingAligned`, which
  moves the line-synced `Text` (frame and multiline alignment) and every visual row of the
  word-timed flow layout (`KaraokeWordFlowLayout`). Alignment moves the line and **never** the
  order the words are read or the direction a fill sweeps: a right-aligned English line is
  still a left-to-right line that happens to sit on the right.

A pause row follows the line above it. Nothing is sung on one and it has no singer of its own —
it is the *silence inside* somebody's section — so the dots belong on the edge of the line they
are a pause in, not on the lead's. `SyncedLyrics.isTrailingAligned(at:)` is that rule, and it is
the one place the display asks: a sung row answers for itself, and a row with nothing to sing
(the dots, or the short `♪` gap) takes the nearest row above that *was* sung, stepping over any
pause rows in between. Rows synthesized for a gap are inserted by `withPauseInterludes` without
an agent of their own — that is what makes the rule a lookup rather than something the insertion
pass has to copy onto them, and it keeps an explicit empty `<p>` inside a duet section reading
the same way.

The fullscreen sheet keeps a **margin on its trailing edge** — `KaraokeLyricsLineView` fills the
width it is given, so a right-aligned line would otherwise end exactly on the panel's right edge.
The leading edge is where the lyrics column starts, beside the artwork, and is left alone.

## Consequences

- A duet reads as a conversation: the second singer's lines answer from the other edge, and a
  solo song is untouched (`isOppositeTurn` stays false for every line, and a single-agent
  document resolves to zero turns).
- The information is carried by the sheet, so it survives everything the display does
  afterwards — the pause rows, the backing-vocal conversion and the scroll all work on rows
  that already know whose turn they are.
- The resolution lives in the parsers rather than in a display-time pass, unlike
  `LyricsBackingParentheses` and `withPauseInterludes`. Those two are properties of the *sheet*
  that a line cannot answer alone; a turn is not — the parser has the metadata in hand and the
  view only needs the line. A display pass would have to keep the whole document around to
  rediscover the lead agent.
- Cache compatibility is unchanged: the field decodes as `false` when a file written before it
  lacks it, and a file with it decodes in any older build because it is an added key.
- **Open question, recorded rather than guessed:** whether Apple Music right-aligns a
  `type="group"` line. This ADR keeps group lines on the lead's side on the grounds that a
  group is everyone rather than the other singer, which is also the only rule that can be
  applied consistently — ELRC names voices without types, so a document that writes `{v3}`
  there is read as a second voice and *is* a turn. If group lines should move, the change is
  the `agentTypes[agent] != "group"` test in `TTMLParser.oppositeTurn(for:)`.

## Verification

- `SingerTurnsTests`: Apple's own duet document resolves to `[false, true, false, false]` across
  `v1`, `v2`, `v3` and a following `v1`; the live single-agent shape resolves to no turns at
  all; an undeclared document is led by the first agent it sings; a `<div>` agent is inherited
  and overridden; Paxsenix's `oppositeTurn` flag and `{vN}` ELRC markers resolve to the same
  field, and a `{bg}` marker does not; the field survives a cache round-trip, costs the cache
  nothing when false, and decodes as false from a file written before it existed. A pause row
  inserted into the second singer's part follows them rather than the lead, two pauses in a row
  follow the last line actually sung, and a pause with nothing above it falls back to its own
  declaration.
- Rendering is verified on pixels, not on the flag: the duet document is parsed and its rows are
  hosted by the panel's own row view, and the ink is measured — the lead singer's line starts
  at the left edge, the second singer's line reaches the right edge of the same width, and the
  group's line follows the lead. The same measurement is run over both render paths (a
  line-synced line and a word-timed one), and over the pause row, whose dots are held to the
  same two edges. Fullscreen draws through the same `KaraokeLyricsLineView` with the same flag;
  its own row frame, scale anchor and new trailing margin were changed the same way but have no
  pixel test, because that view is private to the fullscreen player.
