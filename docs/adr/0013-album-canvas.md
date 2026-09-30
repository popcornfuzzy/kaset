# ADR-0013: Album Canvas in Fullscreen Now Playing

## Status

Accepted

## Context

Kaset's fullscreen now-playing view shows the YouTube Music album artwork as a static image. Streaming services such as Apple Music and Tidal ship *animated* artwork ("canvas"): Tidal provides album video covers as square MP4s, and Apple Music provides artist motion artwork as HLS streams. This feature lets the fullscreen view upgrade the static album art into a looping animated canvas when one exists.

Constraints:

1. **Never replace the album image completely** — the still artwork must render immediately and remain the base layer. The canvas is a background lookup that, once found and ready, smoothly crossfades in.
2. **No secrets in the binary** — Apple Music's catalog access is a web-player JWT. The project rule forbids committing authentication tokens, and any hardcoded token expires. The token must be discovered at runtime.
3. **User control** — a Settings toggle enables/disables the feature, and the canvas cache (lookup results + downloaded videos) must be clearable from Settings.
4. **Track-switch races** — canvas lookups are asynchronous and can overlap when the user skips tracks; stale results must never overwrite newer ones.
5. **Extensibility** — more canvas sources (Spotify canvases, YouTube Music's own motion artwork) should slot in behind the same provider/service model.
6. **No third-party dependencies** — the reference Android implementation uses Ktor; Kaset ports the logic with `URLSession`/`JSONSerialization`.

## Decision

### Service Boundary

Introduce `CanvasService` as an `@MainActor @Observable` environment service that owns:

- `currentCanvas` (the resolved `CanvasArtwork`), `currentCanvasURL` (local file or remote stream), and `currentCanvasVideoId`
- The active provider label
- Lookup caching (memory + disk, TTL-based) keyed by `videoId`
- Download-once video caching for direct files (Tidal MP4s)
- Stale-request protection via a monotonic `fetchGeneration` (same pattern as `SyncedLyricsService`)

`FullscreenNowPlayingView` drives the flow with `.task(id: currentTrack.videoId)`: on open and on track change it builds a `CanvasSearchInfo` (title, artist, album, videoId) and awaits `loadCanvas(for:)`. The task is auto-cancelled on disappear/track change, and lookups wait (up to 10s, 250ms polling) until real track metadata is loaded — mirroring `loadLyricsWhenReady`.

### Provider Layer

Introduce `CanvasProvider` (`Sendable`) with `func fetchCanvas(for info: CanvasSearchInfo) async -> CanvasArtwork?`. Initial providers:

- **`TidalCanvasProvider`** — searches `api.tidal.com/v1/search` with the public embed-player token and returns the first candidate that passes strict normalized validation and carries a `videoCover`, which is formatted into a square 1280×1280 MP4 URL. The search plan is ordered (`searchAttempts(for:)`) so the highest-signal query runs first:
  1. `TRACKS` on **song + artist** (no album). A matched track's nested album carries the same `videoCover` as the album itself, and omitting the album keeps the song's *single* ranked first.
  2. `ALBUMS` on the known album + artist.
  3. `ALBUMS` on song + artist, validated against the song title (catches single releases titled after their lead track).
  4. `TRACKS` on album + artist + song, as the last-resort album-qualified query.
  5. **Album affiliation** — search `ALBUMS` for song + artist, then prove the song is on the album by reading `/v1/albums/{id}/items` and matching the track title. The first album whose track list actually contains the song supplies the canvas.

  Attempt 1 deliberately excludes the album: Tidal ranks a song's *album release* above the single when the album term is present, and that release frequently has no video cover even when the single does (e.g. "Flowers" vs "Endless Summer Vacation").

  Attempt 5 exists because Tidal attaches a video cover to the *album release*, not to the track. "Good Days" by SZA is the canonical case: the single of that name carries no cover, and the song's other release (`SOS Deluxe: LANA`) carries none either, but the `SOS` album does. When the reported album is absent, the deluxe edition, or the single, **nothing** in the track's metadata names `SOS`, so no query built from the known metadata can ever reach it. The album therefore has to be discovered and then verified against its track list. That verification is what keeps the stage safe: an artist's *other* canvased albums can never be shown, because a canvas only wins when the album genuinely contains the requested track. Candidate albums are checked in preference order (the caller's album, then a release titled after the song, then search order) and capped at three album-items requests so a miss cannot fan out without bound.

- **`AppleMusicCanvasProvider`** — discovers the web-player JWT at runtime by scraping the `music.apple.com` web player scripts (validating `iss`/`exp` on the decoded payload), then searches the AMP catalog for the artist and fetches `extend=editorialVideo,editorialArtwork` motion URLs (HLS).

`CanvasService` consults providers **in preference order, one at a time**, and returns the first canvas found. Tidal is primary (`providers[0]`) and Apple Music is the fallback, so a track resolves to Tidal's album-level canvas whenever one exists.

Providers are deliberately *not* raced. Racing made the winner depend on network timing rather than on source quality, so a lower-priority source could decide the result for a track, and it ran Apple Music's multi-request web-player token scrape on every lookup even though Tidal answers almost always. Sequential lookup also means a primary hit never starts the expensive fallback. Both providers are stateless fetchers; all caching lives in `CanvasService` so "Clear Canvas Cache" is unambiguous.

### Matching

Providers share `CanvasMatching.normalizeForComparison`, which folds **diacritics** (NFD, then drop the Combining Diacritical Marks block) and rewrites **punctuation to a space** before collapsing whitespace. Diacritic folding is required because the catalogs disagree on accents — Tidal writes "ROSALÍA" where YouTube Music may write "Rosalia" — and an accent mismatch silently rejected correct results. Punctuation becomes a separator rather than being deleted so hyphenated spellings still match: deleting the hyphen makes "Anti-Hero" normalize to `antihero`, which never equals "Anti Hero"'s `anti hero`.

Unlike the Android reference implementation, non-Latin letters and digits are preserved (`\p{L}`/`\p{N}`, not `[a-z0-9]`). Restricting to ASCII would collapse every Cyrillic, Greek, Arabic, or CJK title to the empty string, which matches nothing meaningful.

### Rendering

The fullscreen `artworkCard` is a `ZStack`:

1. The existing `CachedAsyncImage` still artwork (unchanged base layer).
2. A `CanvasVideoView` (`NSViewRepresentable` whose backing layer is an `AVPlayerLayer`) with `AVQueuePlayer` + `AVPlayerLooper` for seamless looping, muted, `aspectFill`, presented only when `currentCanvasVideoId == currentTrack.videoId` and the feature is enabled and the track is not a podcast.

The canvas view reports `readyToPlay`/`failure` via callbacks; the host crossfades opacity 0 → 1 with a 0.6s ease-in-out only when the first frame can render, skipping animation when Reduce Motion is on. On player-item failure the canvas stays hidden and the still image remains. Exiting fullscreen tears the player down (view deallocation); reopening the same track replays instantly from cache.

The canvas is gated on `playerService.showFullscreenNowPlaying` rather than on the view existing, and the lookup's `.task(id:)` keys on `presentation + videoId`. Fullscreen is a presentation owned by `MainWindow`, not a view lifetime: the host may keep this view mounted across opens (it already keeps the content behind the overlay alive), so no canvas state — the ready/failed flags, the lookup — may depend on being created fresh. Because lookups are cache-backed, re-running one for an unchanged track costs no network request.

### Caching

- **Lookup cache** (`CanvasCache`): one JSON file per `videoId` under `~/Library/Application Support/Kaset/CanvasCache` plus an in-memory layer. Found results expire after 24h; cached misses expire after 6h so unavailable tracks are retried reasonably.
- **Video file cache** (`CanvasVideoFileCache`): downloaded MP4s under `~/Library/Caches/com.kaset.canvascache`, keyed by SHA-256 of the URL, with in-flight download deduplication. HLS streams (Apple Music) are played directly from their remote URL — offline-HLS via `AVAssetDownloadTask` is deliberately out of scope.
- Both caches resolve the real home directory via `getpwuid` (sandbox-safe, same as `LyricsCacheStore`), or the Caches directory for ephemeral video files.

### User Control

- `SettingsManager.animatedCanvasEnabled` (default on) exposed as "Enable Animated Canvas" in a new "Animated Canvas" General Settings section.
- A "Canvas Cache" row shows the combined lookup + video cache size and a "Clear Cache" button that clears both caches and resets in-memory canvas state.

## Consequences

### Positive

- The still album art is never absent — the canvas is strictly an enhancement that crossfades in when ready.
- No secrets in the binary: the Apple Music JWT is discovered at runtime and cached in memory until ~1 minute before expiry.
- Consistent with existing patterns: environment service + concurrent provider search + generation-based race protection + per-track caching, all unit-testable with mock providers.
- Canvas sources are swappable behind the protocol.

### Negative

- **External dependency** — canvas availability depends on Tidal/Apple Music API behavior and uptime; matching heuristics are best-effort.
- **First-play latency** — a direct MP4 is downloaded before it is shown, so the crossfade can trail the lookup by a second or two on slow connections (falls back to streaming on download failure).
- **Apple Music is artist-level, not album-level** — its motion artwork is keyed by artist; Tidal remains the album-level source.

### Neutral

- HLS canvases are streamed rather than stored, so the Settings cache size mostly reflects downloaded Tidal MP4s.
- The blurred fullscreen background layer is unchanged; only the square artwork card animates.
