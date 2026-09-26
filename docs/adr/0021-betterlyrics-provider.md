# ADR-0021: BetterLyrics Provider and Shared TTML Parser

## Status

Accepted. The provider-selection portion is superseded by
[ADR-0022](0022-per-provider-lyrics-settings.md).

## Context

Kaset already resolves word-timed lyrics through Paxsenix, which requires an
Apple Music web-token bootstrap, a catalog search, and then a per-track lyrics
fetch. The BetterLyrics API (`lyrics-api.boidu.dev`) returns Apple Music
TTML for a title/artist pair in a single request and is cheaper and more
predictable to call.

Both sources emit the same `itunes:timing="Word"` TTML, which `PaxsenixProvider`
parsed with a private `XMLParserDelegate`.

## Decision

Add `BetterLyricsProvider` as a selectable lyrics provider and extract the
Apple Music TTML parser into a shared `TTMLParser` used by both Paxsenix and
BetterLyrics.

- The provider sends the exact title and artist (plus optional duration and
  album) to `/getLyrics` and never normalizes them: normalizing can match a
  different edit (radio vs. album) and return lyrics that drift out of sync.
- `TTMLParser` skips spans with `ttm:role="x-translation"` or `"x-roman"` so
  translated/romanized restatements are not appended as out-of-sync words.
- BetterLyrics is added to the default combined provider chain and exposed as
  its own `BetterLyrics`-only option in General settings.

## Consequences

- Word-synced lyrics are available with a single lightweight request, reducing
  reliance on the multi-step Paxsenix flow.
- The provider is an unofficial, third-party API and may be rate-limited or
  changed without notice.
- Availability depends on BetterLyrics' Apple Music catalog coverage.
- No credentials, tokens, or cookies are persisted or logged by Kaset.
