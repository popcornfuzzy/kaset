# ADR-0017: Fullscreen Podcast Experience with YouTube Transcript

## Status

Accepted

## Context

Kaset plays podcast episodes as ordinary tracks, so opening the fullscreen now-playing view for an
episode showed album artwork and (usually missing) song lyrics. Podcasts deserve their own listening
experience: the episode video beside the transcript of what is being said, following Apple Podcasts'
layout — video and episode meta on the left, transcript on the right, transport controls under the
video.

Constraints:

1. **Playback is owned by the hidden WebView.** Kaset never re-implements playback; the singleton
   `SingletonPlayerWebView` is the only player, and it can only live in one place in the view
   hierarchy at a time. The experience must not unmount it or interrupt audio.
2. **Only for podcasts.** The music experience (artwork, synced lyrics, canvas) must be untouched
   for songs.
3. **The transcript is YouTube's transcript** — timed, so the paragraph being spoken can be
   highlighted and followed, and tapping a paragraph seeks playback.
4. **Prefer the API over WebView scraping.** Transcript data must come from the `youtubei` API, not
   from reading the rendered page.
5. **No third-party dependencies, Swift 6 concurrency only.**

## Decision

### Presentation

`PlayerService.isFullscreenPodcastPresented` (fullscreen flag **and** current item is a podcast)
selects the experience. `MainWindow` renders `FullscreenPodcastView` in place of
`FullscreenNowPlayingView` while a podcast episode is the current item, so switching to a song while
fullscreen is open swaps the experiences and the flag keeps working unchanged.

The episode keeps `showFullscreenNowPlaying` as its single fullscreen state, so the existing
entry points (player-bar button, keyboard shortcut) need no podcast-specific paths.

### Video surface: measured slot, not a second owner

`FullscreenPodcastView` does **not** host the WebView. It lays out a video slot and reports its frame
(`onGeometryChange`, in a named coordinate space) to a small `PodcastVideoSlotModel` owned by
`MainWindow`, which places the shared `PersistentPlayerView` layer into that frame with absolute
positioning. This keeps the WebView in one container for the whole app lifetime: nothing is
re-parented, and audio never depends on which view is on screen.

When the slot is unavailable — the episode has no video, or the user turned the video off — the layer
stays mounted at 1×1 with `isExpanded: false`, which restores YouTube's normal page layout while
playback continues. The same mini-player DOM presentation script then extracts the video into the
slot and hides the page chrome when it is shown, exactly as for the floating mini player.

### Transcript source

YouTube Music's own client identity (`WEB_REMIX`) is not served caption tracks: the `player`
endpoint answers without a `captions` object, and the `next` response has no transcript data at all.
The `get_transcript` endpoint exists on `music.youtube.com` but requires an opaque protobuf `params`
blob that is only published on the `www.youtube.com` watch page; sending it back to every client
identity (WEB_REMIX, WEB, ANDROID) is answered with HTTP 400 *precondition check failed*.

The transcript is therefore read from the caption track, which is the same data YouTube's own
transcript panel shows:

1. `POST /player` on `music.youtube.com` with the **ANDROID** client identity
   (`clientName: ANDROID`, `clientVersion: 20.10.38`, `contentCheckOk`/`racyCheckOk`) → returns
   `captions.playerCaptionsTracklistRenderer.captionTracks`.
2. Pick the preferred language (app language, then English, manual track over `asr`).
3. Download the track URL with `fmt=json3` (the URL ships its own `fmt`, which has to be replaced,
   not appended) → timed caption cues.
4. Merge cues into readable paragraphs (a >1.2s pause, or ~240 characters with any gap, starts a new
   paragraph) and keep the first cue's timestamp as the paragraph's start.

Because this request is cookie-less by design, a 401/403 from it is reported as an API error instead
of expiring the session. Caption URLs are signed and short-lived, so they are fetched immediately and
never cached; only the parsed transcript is cached, in memory, per episode.

Caption availability is best-effort: episodes without a caption track (or with YouTube's "PoToken
required" caption variant) show a "No transcript available" state with a manual refresh action.

### Playback speed

Podcasts are commonly listened to above 1×, so the experience owns a speed control. `PlayerService`
gains a persisted `playbackRate` applied through the WebView; the page-side enforcement loop
re-asserts the rate whenever YouTube recreates the video element (track change, ad transition), which
is the same mechanism that already protects volume.

### Sleep timer

A local, view-scoped sleep timer (5–60 minutes) pauses playback when it expires. It is deliberately
not persisted: it belongs to one listening session.

## Consequences

### Positive

- Playback and the WebView layer are untouched by the new experience; opening/closing it cannot
  interrupt audio.
- The transcript is timed, so it doubles as a seek surface, and paragraph highlighting follows
  playback the way the synced-lyrics view already does.
- The transcript request reuses the existing client, session, caching and error plumbing.

### Negative

- **Unofficial endpoint usage** — the caption tracks come from the mobile client identity, which
  YouTube can change or gate (PoToken) at any time; the feature degrades to "no transcript".
- **Language coverage** — a transcript exists only where YouTube has captions, and auto-generated
  text has no punctuation or speaker labels.
- **A second client identity** lives in `YTMusicClient` next to `WEB_REMIX`, which has to be kept in
  mind when the API generation changes.

### Neutral

- Transcript fetching ignores the account context (cookies/brand account), so it is unaffected by
  account switching.
- The video slot's geometry crosses the view boundary through one observable model; the fullscreen
  view owns layout, `MainWindow` owns the layer.
