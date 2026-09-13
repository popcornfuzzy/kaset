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

- **`TidalCanvasProvider`** — searches `api.tidal.com/v1/search` with the public embed-player token, preferring an album-level match (`ALBUMS`, strict normalized album + artist validation) over a track-level match (`TRACKS`, strict song + artist validation). The `videoCover` ID is formatted into a square 1280×1280 MP4 URL.
- **`AppleMusicCanvasProvider`** — discovers the web-player JWT at runtime by scraping the `music.apple.com` web player scripts (validating `iss`/`exp` on the decoded payload), then searches the AMP catalog for the artist and fetches `extend=editorialVideo,editorialArtwork` motion URLs (HLS).

`CanvasService` runs all providers **concurrently** and the first valid result wins (mirrors the synced-lyrics multi-provider search). Both providers are stateless fetchers; all caching lives in `CanvasService` so "Clear Canvas Cache" is unambiguous.

### Rendering

The fullscreen `artworkCard` is a `ZStack`:

1. The existing `CachedAsyncImage` still artwork (unchanged base layer).
2. A `CanvasVideoView` (`NSViewRepresentable` whose backing layer is an `AVPlayerLayer`) with `AVQueuePlayer` + `AVPlayerLooper` for seamless looping, muted, `aspectFill`, presented only when `currentCanvasVideoId == currentTrack.videoId` and the feature is enabled and the track is not a podcast.

The canvas view reports `readyToPlay`/`failure` via callbacks; the host crossfades opacity 0 → 1 with a 0.6s ease-in-out only when the first frame can render, skipping animation when Reduce Motion is on. On player-item failure the canvas stays hidden and the still image remains. Exiting fullscreen tears the player down (view deallocation); reopening the same track replays instantly from cache.

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
