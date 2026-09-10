# ADR-0013: Musixmatch Rich-Sync Lyrics Provider

## Status

Accepted

## Context

Kaset already supports timed lyric lines and optional word timestamps, but LRCLIB normally provides line-level LRC timing. Word-by-word timing is available through the unofficial desktop-client protocol used by Musixmatch integrations.

## Decision

Add Musixmatch as a selectable lyric provider and make it the default. The provider uses the desktop endpoint flow (`token.get`, `matcher.track.get`, `track.richsync.get`, and `track.subtitle.get`) and converts rich-sync records into Kaset's existing `TimedWord` model. LRCLIB remains available as an explicit alternative.

Provider selection is strict for debugging: only the selected provider is queried. If it returns no result, the UI displays an informal unavailable message rather than silently using another provider.

Word timing is rendered by shared behavior in the side-panel and fullscreen lyric views. Sung words use the accent color while upcoming words remain subdued, with a short ease-out transition driven by the existing playback time polling.

## Consequences

- Word-level karaoke timing is available without a user API key.
- The integration is unofficial, undocumented by Musixmatch as a public client API, and may be rate-limited or changed without notice.
- Lyrics availability depends on Musixmatch's matching and rich-sync catalog.
- No credentials, tokens, or cookies are persisted or logged by Kaset.
- Users can switch back to LRCLIB in General settings.
