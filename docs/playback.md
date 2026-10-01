# Playback System

This document details the WebView-based playback system, its architecture, and implementation notes.

## Overview

YouTube Music uses DRM (Widevine) to protect Premium content. Native playback via AVPlayer is not possible because:

1. **Bot Detection**: YouTube's APIs detect non-browser clients and block them
2. **DRM**: Premium content requires Widevine CDM, only available in WebKit
3. **User Interaction**: YouTube requires a user gesture to start playback

Our solution: A **singleton WebView** that loads YouTube Music watch pages and plays audio through WebKit's native DRM support.

## Architecture

### Components

| Component | File | Purpose |
|-----------|------|---------|
| `SingletonPlayerWebView` | `MiniPlayerWebView.swift` | Manages the one-and-only WebView |
| `PersistentPlayerView` | `MiniPlayerViews.swift` | SwiftUI wrapper for the WebView |
| `PlayerWebViewPreload` | `PlayerWebViewLoading.swift` | When the layer is hosted and the shell loaded |
| `PlayerBarLoadingWash` | `PlayerBarLoadingWash.swift` | The wash in the bar's capsule while it waits |
| `PlayerService` | `PlayerService.swift` | Playback state and control |
| `PlayerService+WebQueueSync` | `PlayerService+WebQueueSync.swift` | Keeps native queue state authoritative when WebView events drift |
| `AppDelegate` | `AppDelegate.swift` | Window lifecycle for background audio |

### Singleton Pattern

```swift
@MainActor
final class SingletonPlayerWebView {
    static let shared = SingletonPlayerWebView()

    private(set) var webView: WKWebView?
    var currentVideoId: String?

    func getWebView(webKitManager:, playerService:) -> WKWebView
    func loadVideo(videoId: String)
}
```

**Why Singleton?**
- Prevents multiple audio streams
- Survives SwiftUI view recreation
- Survives window close/reopen
- Single source of truth for playback

## Playback Flow

### 1. User Initiates Play

```swift
// In a view
playerService.play(videoId: "dQw4w9WgXcQ")
```

This sets:
- `pendingPlayVideoId` = video ID
- `showMiniPlayer` based on playback type:
    - Podcast episodes auto-open the mini player
    - Normal songs stay hidden by default
    - First hidden song can arm a one-shot fallback that reveals the mini player if autoplay does not start quickly

### 2. WebView Loads

`MainWindow` hosts the player layer for the whole signed-in session, not only while a video is
pending, so the WebView exists — and is already showing the YouTube Music shell — before the first
play ([ADR-0027](adr/0027-player-webview-preload-and-loading-strip.md)):

```swift
if PlayerWebViewPreload.shouldHostPlayerWebView(
    isSignedIn: authService.state.isLoggedIn,
    hasPendingVideo: playerService.pendingPlayVideoId != nil
) {
    PersistentPlayerView(videoId: playerService.pendingPlayVideoId, isExpanded: playerService.showMiniPlayer)
        .frame(width: showMiniPlayer ? 160 : 1, height: showMiniPlayer ? 90 : 1)
}
```

With nothing playing yet, the representable gives the empty WebView one of two pages:

- the **active track's watch page**, when a restored session has a song that has not been resumed.
  It is loaded with `kaset_preload=1` and, when the session has a position, YouTube's own `t`
  parameter, so the page is already in place and at the right position when play is pressed;
- the **shell** (`music.youtube.com`, also preload-flagged) when there is no track to be ready for.

Both are *held*: Kaset permits autoplay, so a page left to itself would start playing on its own. The
document-start gate (`SingletonPlayerWebView.preloadGateScript`) swallows the page's `play()` calls
until a control Kaset drives lifts the hold, the user clicks or types in the page, or the mini player
is revealed for the user to use.

While a page is `empty`, `shell` or `preloaded`, it may only report what
`PlayerWebViewPage.observation` (`PlayerWebViewObservation`) allows. The shell has no track and
reports nothing; a preloaded page is a player that was told it started when its autoplay was
swallowed, so it reports **only which track it is holding** — title, artist, artwork, video id — and
none of its playback state, ads, end-of-track or remote-control signals. Taking those would put a
track that is not playing into the app's state and would zero the progress a restored session is
showing, and would let a silent page drive the queue.

What a preloaded page does contribute goes to `PlayerService.reconcilePreloadedTrackMetadata` rather
than `updateTrackMetadata`: the artist byline is normalized, the complete observation is published to
`observedWebMetadata` (which is what the lyrics pipeline waits on), the playback kind is refined, and
the page's artwork is adopted when the held track has none. The queue stays the authority on what is
playing, on the order and on the rest of its row (album, duration, like state), and the
queue-divergence handlers are never fed from a page that is not playing.

Its title and artist are the exception: when the page reports a byline that is not equivalent to the
held row's — shelf rows carry the album and year as extra artist entries, so their display
("SXTN, Leben am Limit, 2017") never matches the player-bar byline ("SXTN") — those two strings are
taken from the page, because that is exactly what pressing play used to do and nothing did at rest. It
only happens when the page also reports the held track's video ID, so a shell, a half-rendered page or
an ad cannot rename the track.

Both waits are reported into `PlayerService` and drawn by the player bar's loading wash
(`PlayerBarLoadingRule`): the **bar's own capsule is the mask**, the wash sits under the controls, and it
is drawn in the bar's foreground colour rather than the brand accent — which is what keeps it legible on
the light bar. A page load deepens it from the left, from WebKit's own `estimatedProgress`; a wait with
nothing to measure is the pulse on its own. A page load that ends keeps pulsing for a fixed tail
(`PlayerBarLoadingLinger.tail`), because the launch preload can be over before the window has finished
appearing: without it the wash is a flash nobody sees.

### 3. Video Starts

`PersistentPlayerView` either:
- Creates new WebView (first play)
- Reuses existing WebView (subsequent plays)

```swift
func makeNSView(context: Context) -> NSView {
    let webView = SingletonPlayerWebView.shared.getWebView(...)

    // Load if different video
    if SingletonPlayerWebView.shared.currentVideoId != videoId {
        webView.load(URLRequest(url: watchURL))
    }

    return container
}
```

When playback transitions to `isPlaying`:
- Fallback-driven mini player reveals auto-dismiss and mark user interaction
- Podcast auto-open does not auto-dismiss (stays visible)
- User-toggled mini player visibility is preserved until toggled off

### 4. State Updates

The observer script continuously reports:
- Playback state (`isPlaying`, `progress`, `duration`)
- Track metadata (`title`, `artist`, `thumbnailUrl`)
- The observed `videoId`
- Whether the observer thinks the track changed
- Like status and lightweight video availability

Swift updates `PlayerService` from every `STATE_UPDATE`, then uses
`PlayerService+WebQueueSync` to decide whether the reported track matches
Kaset's queue or whether YouTube autoplay needs to be corrected.

### 5. Track-End Handling

Natural track completion is handled by a dedicated bridge event:

```javascript
bridge.postMessage({
    type: 'TRACK_ENDED',
    videoId: lastVideoId || currentVideoId()
});
```

Swift validates that the ended `videoId` still matches the expected queue song
before advancing. This prevents stale `ended` events from double-advancing the
queue after Kaset has already loaded the next track.

## Track Changing

When user plays a different track:

1. `pendingPlayVideoId` changes
2. SwiftUI calls `updateNSView` (not `makeNSView`)
3. `SingletonPlayerWebView.loadVideo(videoId:)` called
4. Current audio paused, target volume prepared, new URL loaded

```swift
func loadVideo(videoId: String) {
    guard videoId != currentVideoId else { return }

    // Update ID immediately to prevent duplicate loads
    currentVideoId = videoId

    // Pause current, set the target volume, then load new
    webView.evaluateJavaScript("document.querySelector('video')?.pause()") { _, _ in
        webView.evaluateJavaScript("window.__kasetTargetVolume = currentVolume")
        self.webView?.load(URLRequest(url: watchURL))
    }
}
```

When the WebView reports a new `videoId`, Kaset treats that as authoritative
even if the DOM title/artist are still stale. This avoids a race where YouTube
switches tracks before the player bar text catches up.

## Background Audio

### Window Close Behavior

By default, closing a window destroys its view hierarchy, killing the WebView. We prevent this:

```swift
// AppDelegate.swift
extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)  // Hide instead of close
        return false          // Don't actually close
    }
}
```

### App Lifecycle

```swift
func applicationShouldTerminateAfterLastWindowClosed(_:) -> Bool {
    return false  // Keep app running when window hidden
}
```

### Reopening Window

```swift
func applicationShouldHandleReopen(_:, hasVisibleWindows:) -> Bool {
    if !hasVisibleWindows {
        for window in NSApplication.shared.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return true
        }
    }
    return true
}
```

### Flow Summary

| Action | Result |
|--------|--------|
| Close window (⌘W) | Window hides, audio continues |
| Click dock icon | Window reappears, same audio |
| Quit app (⌘Q) | App terminates, audio stops |

## JavaScript Bridge

### Observer Script

Injected into every watch page. The real script is more defensive than the
minimal version below:

```javascript
(function() {
    'use strict';
    const bridge = window.webkit.messageHandlers.singletonPlayer;
    let lastTitle = '';
    let lastArtist = '';
    let lastVideoId = '';

    function currentVideoId() {
        const player = document.querySelector('ytmusic-player');
        const data = player?.playerApi?.getVideoData?.();
        return data?.video_id || data?.videoId || '';
    }

    function sendTrackEnded() {
        bridge.postMessage({
            type: 'TRACK_ENDED',
            videoId: lastVideoId || currentVideoId()
        });
    }

    function sendUpdate() {
        const video = document.querySelector('video');
        const progressBar = document.querySelector('#progress-bar');
        const title = /* DOM title, or player API title if DOM is stale */;
        const artist = /* DOM artist, or player API artist if DOM is stale */;
        const videoId = currentVideoId();
        const trackChanged =
            (title !== '' && (title !== lastTitle || artist !== lastArtist))
            || (videoId !== '' && videoId !== lastVideoId);

        if (trackChanged) {
            if (title !== '') {
                lastTitle = title;
                lastArtist = artist;
            }
            if (videoId !== '') {
                lastVideoId = videoId;
            }
        }

        bridge.postMessage({
            type: 'STATE_UPDATE',
            isPlaying: video ? !video.paused : false,
            progress: parseInt(progressBar?.getAttribute('value') || '0'),
            duration: parseInt(progressBar?.getAttribute('aria-valuemax') || '0'),
            title: title,
            artist: artist,
            videoId: videoId,
            trackChanged: trackChanged
        });
    }
})();
```

### Message Handler

```swift
func userContentController(_:, didReceive message: WKScriptMessage) {
    guard let body = message.body as? [String: Any],
          let type = body["type"] as? String
    else { return }

    Task { @MainActor in
        if type == "TRACK_ENDED" {
            await playerService.handleTrackEnded(
                observedVideoId: body["videoId"] as? String
            )
            return
        }

        playerService.updatePlaybackState(...)
        playerService.updateTrackMetadata(...)
    }
}
```

### Queue Authority

Kaset treats its own queue as the source of truth whenever one exists:
- `handleTrackEnded(observedVideoId:)` advances the native queue immediately
- `updateTrackMetadata(...)` accepts `videoId`-only transitions even if the DOM
  metadata is temporarily blank or stale
- If YouTube advances to an unexpected track near the end of a song, Kaset
  replays the expected queue track instead of inheriting YouTube autoplay
- At the end of a non-repeating queue, Kaset marks playback ended rather than
  allowing autoplay to continue into unrelated tracks

## Mini Player UI

A small toast in the bottom-right corner:

| State | Size | Purpose |
|-------|------|---------|
| Visible | 160×90 | User clicks to interact |
| Hidden | 1×1 | WebView stays in hierarchy |

```swift
.frame(
    width: playerService.showMiniPlayer ? 160 : 1,
    height: playerService.showMiniPlayer ? 90 : 1
)
```

### Auto-Dismiss

When playback starts, the mini player auto-dismisses:

```swift
// In Coordinator
if isPlaying && playerService.showMiniPlayer {
    playerService.confirmPlaybackStarted()
}
```

## Common Issues

### Multiple Audio Streams

**Cause**: Multiple WebViews created

**Solution**: Singleton pattern ensures one WebView

### Audio Stops on Window Close

**Cause**: WebView destroyed with view hierarchy

**Solution**: `windowShouldClose` returns `false`, hides instead

### Track Not Changing

**Cause**: `updateNSView` not called

**Solution**: Pass `videoId` as parameter to trigger SwiftUI updates

### No Playback

**Cause**: User interaction required by YouTube

**Solution**: Mini player toast allows user to click play

## User Agent

We use Safari's user agent to avoid "browser not optimized" warnings:

```swift
static let userAgent = """
    Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) \
    AppleWebKit/605.1.15 (KHTML, like Gecko) \
    Version/17.0 Safari/605.1.15
    """
```

## Debugging

Enable WebView inspector in Debug builds:

```swift
#if DEBUG
    webView.isInspectable = true
#endif
```

Right-click the mini player → "Inspect Element" to debug JavaScript.

## Infinite Mix

When playing artist mixes (`RDEM...` playlists), the app supports infinite queue loading:

### How It Works

1. **Initial Load**: `playWithMix()` fetches ~50 songs via the `next` endpoint
2. **Continuation Token**: The API returns a `nextRadioContinuationData.continuation` token
3. **Auto-Fetch**: When ≤10 songs remain in queue, `fetchMoreMixSongsIfNeeded()` loads more
4. **Duplicate Filter**: New songs are filtered to prevent duplicates
5. **Repeat**: Process continues until no more continuation tokens

### Key Components

| Component | Purpose |
|-----------|----------|
| `RadioQueueResult` | Holds songs + continuation token |
| `mixContinuationToken` | Stored in `PlayerService` |
| `isFetchingMoreMixSongs` | Prevents concurrent fetches |
| `fetchMoreMixSongsIfNeeded()` | Triggered on `next()` and `playFromQueue()` |

### State Reset

The continuation token is cleared when:
- Playing a regular queue (`playQueue`)
- Playing song radio (`playWithRadio`)
- Clearing the queue (`clearQueue`)

This prevents infinite fetch from triggering on non-mix playback.

## Google Cast

Casting sends Kaset's audio to a Google Cast device; see [ADR-0015](adr/0015-chromecast-audio-casting.md) for why the
approach was chosen over the official SDK and the YouTube Lounge protocol. AirPlay is no longer offered.

Kaset stays the player: the audio the WebView decodes is captured, encoded, and served to the device's built-in
Default Media Receiver, so the queue, seeking, and track changes keep working exactly as they do locally.

| Stage | Component | Notes |
|-------|-----------|-------|
| Discovery | `CastDeviceDiscovery` | Browses `_googlecast._tcp`; name, model, and id come from the TXT record, and each device is listed the moment mDNS reports it |
| Capture | `AudioProcessTap`, `CastAudioProcessResolver` | Core Audio process tap over Kaset and WebKit's XPC helpers, muted while tapped |
| Encode | `AACStreamEncoder`, `ADTSHeader` | AAC-LC at 192 kbps, framed as `audio/aac` |
| Serve | `LocalAudioStreamServer` | Endless chunked HTTP response on an ephemeral port |
| Hand over | `CastConnection`, `CastReceiverSession` | CASTV2 over TLS to port 8009, `LOAD` on `CC1AD845` |
| Coordinate | `CastService` | Device list, session state, and the player bar's cast menu |

### Notes and limitations

- The first cast triggers the macOS local-network, firewall, and **system audio recording** prompts. Capture
  needs the audio recording permission (`kTCCServiceAudioCapture`), declared through
  `NSAudioCaptureUsageDescription` and the sandbox's audio input entitlement; the grant lives under
  System Settings → Privacy & Security → Screen & System Audio Recording. Without it the tap still runs and
  still mutes the Mac, but streams silence — the cast log calls that out explicitly.
- Audio is captured after decoding, so DRM-protected tracks, podcasts, and ads all cast unchanged.
- The Cast menu lists a device as soon as mDNS reports it — measured at ~20 ms, since nothing is resolved
  before publishing — and keeps the last known devices while a fresh browse runs, so reopening or refreshing the
  menu is instant. A browse that no longer sees a device removes it from the list.
- The slider shapes the stream rather than the device volume; a paused track simply stops sending audio.
- The device must be able to reach the Mac, so guest Wi-Fi and AP isolation block casting.
- WebKit renders playback in helper processes `launchd` owns, not the app, so the tap selects them from Core
  Audio's process list. Another WebKit-based app playing at the same time is captured too.

### When casting does not play

The cast log names the stage it stopped at, which separates the three failure modes:

```bash
log show --last 5m --predicate 'subsystem == "com.sertacozercan.Kaset"' --info | grep -i cast
```

| Log line | Meaning |
|----------|---------|
| `Connecting to Cast device at …` then `Never reached …` | The network blocked the control connection |
| `Connected to Cast device` then `Stream server listening on port …` | The control path works |
| `Tapping N process(es) for audio capture: …` | Which processes the tap covers; the app and WebKit's `com.apple.WebKit.GPU` should be listed |
| `Cast receiver connected to the audio stream` | The device fetched the stream URL |
| `Captured the first buffer from the audio tap` | Audio is being captured; without it the stream is empty |
| `The audio tap has captured nothing 5s after starting` | The tap is not receiving audio — the device will show a spinner forever. Start the track playing and cast again: the tap set is resolved when casting starts, and WebKit's helper must have opened the audio hardware by then. |
| `The audio tap has delivered only silence 5s after starting` | The system audio recording permission is missing. Grant it in System Settings → Privacy & Security → Screen & System Audio Recording and cast again. |

## Song/Video Variant Matching

A track often exists as both a song (`MUSIC_VIDEO_TYPE_ATV`) and a music video
(`MUSIC_VIDEO_TYPE_OMV`); playlists and radio mixes frequently carry the video. Kaset plays the
song version everywhere — queue, direct play, radio/mix, session restore — so the now-playing and
queue show the album art, and keeps the video for the PiP miniplayer. See
[ADR-0028](adr/0028-song-video-variant-matching.md).

| Component | File | Purpose |
|-----------|------|---------|
| `SongVariantMatcher` | `Sources/Kaset/Services/Player/SongVariantMatcher.swift` | Resolves entries to the song variant, scores search candidates, caches results |
| `PlaylistPanelItemParser` | `Sources/Kaset/Services/API/Parsers/PlaylistPanelItemParser.swift` | Reads the `playlistPanelVideoWrapperRenderer` counterpart |
| `SongCounterpart` | `Sources/Kaset/Models/Song.swift` | Flat pairing stored on `Song` |

- The pairing is the API's song/video switcher when present, else a filtered song search scored on
title, artist and length (`searchSongs`).
- Resolution runs ahead of playback for the next `PlayerService.variantResolutionWindow` entries,
so a video is swapped before it starts.
- A known video counterpart makes `hasVideoSurface` true; expanding the miniplayer clicks
YouTube's Video tab. `PlayerService+WebQueueSync.canonicalPlaybackVideoId(for:)` folds the video
page's id back onto the song so the queue does not see drift and the album art is kept.
- The behavior is gated by **Settings → General → Prefer Audio (Song) Versions** (default on).

## Video Mode

For floating video window functionality, see [docs/video.md](video.md).

## Future Improvements

- [x] Queue management (next/previous)
- [x] Infinite mix loading
- [x] Video mode (floating video window)
- [x] Seek support via JavaScript
- [x] Volume control
- [x] Now Playing in Control Center (via WKWebView media session + remote commands)
