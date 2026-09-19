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

### Video surface: anchor-declared slot, not a second owner

`FullscreenPodcastView` does **not** host the WebView. It marks the video slot with an
`anchorPreference` (`PodcastVideoSlotAnchor`), and `MainWindow` resolves that anchor in an
`overlayPreferenceValue` `GeometryReader` and places the shared `PersistentPlayerView` layer on the
resolved rect. This keeps the WebView in one container for the whole app lifetime: nothing is
re-parented, and audio never depends on which view is on screen.

Two details in that plumbing are deliberate:

- **An anchor, not a reported frame.** Preferences are collected on *every* layout pass, so the slot
  is known in the first frame; a reported frame that arrives through a geometry-change callback or a
  named coordinate space has to be kept in sync between two views and can silently never arrive,
  which left the layer at 1×1 while the slot was on screen. Resolving the anchor against the very
  container the layer is drawn in also makes the placement immune to safe-area differences between
  the two views.
- **The presentation stays expanded.** The layer is drawn above the fullscreen view (an overlay is
  above the view it is attached to, so no `zIndex` juggling) and stays expanded at the slot's size for
  the whole session, including while the video is hidden; only its opacity follows the video toggle.
  Handing the `<video>` element back to YouTube and re-extracting it on every toggle is what made
  switching the video off blank the slot and switching it back on never restore the picture.

The same mini-player DOM presentation script extracts the video into the slot and hides the page
chrome, exactly as for the floating mini player. Because the layer keeps its presentation, the toggle
is instant and playback is unaffected.

### Episode artwork

The slot shows the episode artwork whenever the video is hidden, and the episode icon next to the
show name uses the same picture. Both fall back to the episode's generated YouTube still
(`i.ytimg.com/vi/<videoId>/hqdefault.jpg`) when the API's thumbnail is absent or its signed query has
expired — the still is requested without a signature, so it is the one picture that always resolves.

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

### Chapters

The transcript is grouped under the episode's chapters, and a chapter heading seeks to its start.
Chapters come from the timestamped lines creators put in the episode description
(`videoDetails.shortDescription`), which is the same input YouTube turns into chapters on the watch
page — the music clients return no separate chapter or marker structure, so the description is the
only chapter source available. The description arrives in the *same* `player` response the transcript
already fetches, so chapters cost no extra request.

Detection mirrors YouTube's own rules, so a description full of incidental timestamps yields no
headings: the first timestamp must be `0:00`, at least three chapters must exist, they must ascend,
each must be at least ten seconds after the previous one, and none may start past the episode's
length. A failing description simply leaves the transcript ungrouped — chapters are additive, never
required.

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
- Chapters ride along with the transcript request and its cache, and their headings are sticky while
  their paragraphs scroll, so the current chapter stays readable.

### Negative

- **Unofficial endpoint usage** — the caption tracks come from the mobile client identity, which
  YouTube can change or gate (PoToken) at any time; the feature degrades to "no transcript".
- **Language coverage** — a transcript exists only where YouTube has captions, and auto-generated
  text has no punctuation or speaker labels.
- **Chapter coverage** — an episode is chaptered only when its creator timestamped the description,
  so many episodes show a flat transcript.
- **A second client identity** lives in `YTMusicClient` next to `WEB_REMIX`, which has to be kept in
  mind when the API generation changes.

### Neutral

- Transcript fetching ignores the account context (cookies/brand account), so it is unaffected by
  account switching.
- The video slot crosses the view boundary as an anchor preference plus one small observable
  preferences object; the fullscreen view owns layout, `MainWindow` owns the layer.
- The layer is deliberately kept expanded while the video is hidden, so the page-side video element
  stays extracted and the toggle is a pure opacity change rather than a DOM round trip.
