# ADR-0024: Unison Community Lyrics Provider

## Status

Accepted

## Context

Kaset's word-synced lyrics come from Apple Music catalogs (BetterLyrics,
Paxsenix) or line-synced LRC (KuGo, LRCLIB). None of these is a
community-maintained, YouTube-keyed source, so covers, live versions, and
non-catalog tracks that the community has synced often come back empty even
when a good synced version exists.

Unison (`unison.boidu.dev`) is a public database of community-synced lyrics and
the source the Better Lyrics browser extension reads from. Entries are keyed on
a `videoId`, reads need no key or sign-in, and responses are wrapped as
`{ success, data }`.

## Decision

Add `UnisonProvider` as a selectable lyrics provider:

- Lookups are keyed on the track's `videoId` first (`GET /lyrics?v=`), since
  Unison is keyed on it and the match is exact. A miss falls back to
  `GET /lyrics?song=&artist=` with the optional album and duration.
- The envelope's `success` flag is checked before `data`; a `404` or
  `success: false` body is treated as "no lyrics matched", not an error.
- Each record declares its own `format`: `ttml` is parsed with the shared
  `TTMLParser` (word-synced for `richsync`, line-synced for `linesync`), `lrc`
  with the shared `LRCParser`, and anything else is treated as plain text.
- The provider declares `.word` capability and reads only — no credentials are
  stored or logged.
- Every record credits its submitter, so results carry a `LyricsAttribution`
  (name, the public `unison.boidu.dev/curator/<keyId>` profile, and the
  submitter's avatar when they uploaded one). The credit renders at the *end of
  the lyric sheet* — in both the sidebar panel and the fullscreen player — so it
  stays out of the reading area until the reader reaches the bottom; the link is
  styled as a caption, not with the system accent. The sticky footer under the
  panel keeps the plain `Source: Unison` line and the variant picker.
- Unison's site falls back to a client-generated identicon (an inline SVG seeded
  by `keyId`) when a submitter has uploaded no avatar. That identicon is not
  served by the API, so Kaset shows the uploaded avatar when there is one and a
  monogram otherwise.
- A video can hold several community versions, so `UnisonProvider` also
  conforms to `LyricsVariantProvider`. Once a Unison result is on screen, the
  service fetches `/lyrics/variants/:videoId` and exposes a picker in the
  lyrics footer when more than one version renders. The chosen version becomes
  the song's cached result; the list itself is memory-only.
- Unison is added to the default provider order after Paxsenix, with a host
  probe for the Provider Status card. Legacy single-choice presets migrate to
  a disabled set that also excludes Unison, so an existing user's selection is
  not silently widened.

## Consequences

- Community-synced word timing is available for tracks missing from Apple Music
  catalogs, at the cost of one or two requests per search.
- Unison rate limits reads to 120 requests per minute per IP; a search makes at
  most two, plus one variant list when Unison supplies the shown lyrics. Results
  are cached per song by `SyncedLyricsService`.
- The provider is an unofficial, third-party API and may be rate-limited or
  changed without notice.
- Community submissions vary in quality; the top-ranked record for a video is
  used without further vetting.
