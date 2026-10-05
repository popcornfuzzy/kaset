# Architecture & Services

This document provides detailed information about Kaset's architecture, services, and design patterns.

## Core Structure

The codebase follows a clean architecture pattern:

```
Sources/
  └── Kaset/            → Main app target
      ├── KasetApp.swift    → App entry point (scenes, commands, root view)
      ├── AppDelegate.swift → Window lifecycle (creates the app's main window)
      ├── Models/       → Data types (Song, Playlist, Album, Artist, etc.)
      ├── Services/     → Business logic
      │   ├── API/      → YTMusicClient, Parsers/
      │   ├── Auth/     → AuthService (login state machine)
      │   ├── Player/   → PlayerService, NowPlayingManager (media keys)
      │   ├── Scripting/→ ScriptCommands (AppleScript integration)
      │   ├── WebKit/   → WebKitManager (cookie persistence)
      │   └── HapticService.swift → Force Touch trackpad haptic feedback
      ├── ViewModels/   → State management (HomeViewModel, etc.)
      ├── Utilities/    → Helpers (DiagnosticsLogger, extensions)
      └── Views/        → SwiftUI views (MainWindow, Sidebar, PlayerBar, etc.)
  └── APIExplorer/      → API explorer CLI tool
Tests/                  → Unit tests (KasetTests/)
docs/                   → Documentation
  └── adr/              → Architecture Decision Records
```

## Service Protocols

All major services have protocol definitions for testability:

```swift
// Sources/Kaset/Services/Protocols.swift
protocol YTMusicClientProtocol: Sendable { ... }
protocol AuthServiceProtocol { ... }
protocol PlayerServiceProtocol { ... }
```

ViewModels accept protocols via dependency injection with default implementations:

```swift
@MainActor @Observable
final class HomeViewModel {
    private let client: YTMusicClientProtocol

    init(client: YTMusicClientProtocol = YTMusicClient.shared) {
        self.client = client
    }
}
```

## State Management

- **Source of Truth**: Services are `@MainActor @Observable` singletons
- **Environment Injection**: Views access services via `@Environment`
- **Cookie Persistence**: `WKWebsiteDataStore` with persistent identifier

## Key Services

### WebKitManager

**File**: `Sources/Kaset/Services/WebKit/WebKitManager.swift`

Manages WebKit infrastructure for the app:

- Owns a persistent `WKWebsiteDataStore` for runtime cookie storage
- Backs up auth cookies to **macOS Keychain** for persistence across app updates
- Provides cookie access via `getAllCookies()`
- Observes cookie changes via `WKHTTPCookieStoreObserver`
- Creates WebView configurations with shared data store

```swift
@MainActor @Observable
final class WebKitManager {
    static let shared = WebKitManager()

    func getAllCookies() async -> [HTTPCookie]
    func createWebViewConfiguration() -> WKWebViewConfiguration
}
```

### AuthService

**File**: `Sources/Kaset/Services/Auth/AuthService.swift`

Manages authentication state:

| State | Description |
|-------|-------------|
| `.loggedOut` | No valid session |
| `.loggingIn` | Login sheet presented |
| `.loggedIn` | Valid `__Secure-3PAPISID` cookie found |

**Key Methods**:
- `checkLoginStatus()` — Checks cookies for valid session
- `startLogin()` — Presents login sheet
- `sessionExpired()` — Handles 401/403 from API

### YTMusicClient

**File**: `Sources/Kaset/Services/API/YTMusicClient.swift`

Makes authenticated requests to YouTube Music's internal API:

- Computes `SAPISIDHASH` authorization per request
- Uses browser-style headers to avoid bot detection
- Throws `YTMusicError.authExpired` on 401/403
- Delegates response parsing to modular parsers

**Endpoints**:
- `getHome()` → Home page sections (with pagination via `getHomeContinuation()`)
- `getExplore()` → Explore page (new releases, charts, moods)
- `search(query:)` → Search results
- `getLibraryPlaylists()` → User's playlists
- `getLikedSongs()` → User's liked songs (with pagination via `getLikedSongsContinuation()`)
- `getPlaylist(id:)` → Playlist details (with pagination via `getPlaylistContinuation()`)
- `getPlaylistAllTracks(playlistId:)` → All tracks via queue API (for radio playlists)
- `getArtist(id:)` → Artist details with songs and albums
- `getLyrics(videoId:)` → Lyrics for a track (two-step: next → browse)
- `rateSong(videoId:rating:)` → Like/dislike a song
- `subscribeToArtist(channelId:)` → Subscribe to an artist
- `unsubscribeFromArtist(channelId:)` → Unsubscribe from an artist
- `subscribeToPlaylist(playlistId:)` → Add playlist to library
- `unsubscribeFromPlaylist(playlistId:)` → Remove playlist from library

### API Parsers

**Directory**: `Sources/Kaset/Services/API/Parsers/`

Response parsing is extracted into specialized modules:

| Parser | Purpose |
|--------|---------|
| `ParsingHelpers.swift` | Shared utilities (thumbnails, artists, duration) |
| `HomeResponseParser.swift` | Home/Explore page sections |
| `SearchResponseParser.swift` | Search results |
| `PlaylistParser.swift` | Playlist details, library playlists, queue tracks, pagination |
| `ArtistParser.swift` | Artist details (songs, albums, subscription status) |
| `RadioQueueParser.swift` | Radio queue from "next" endpoint |
| `SongMetadataParser.swift` | Full song metadata with feedback tokens |
| `LyricsParser.swift` | Lyrics extraction |

**Design**: Static enum-based parsers with pure functions for testability.

### PlayerService

**File**: `Sources/Kaset/Services/Player/PlayerService.swift`

Controls audio playback via singleton WebView:

| Property | Type | Description |
|----------|------|-------------|
| `currentTrack` | `Song?` | Currently playing track |
| `isPlaying` | `Bool` | Playback state |
| `progress` | `Double` | Current position (seconds) |
| `duration` | `Double` | Track length (seconds) |
| `pendingPlayVideoId` | `String?` | Video ID to play |
| `showMiniPlayer` | `Bool` | Mini player visibility |
| `showLyrics` | `Bool` | Lyrics panel visibility |
| `nowPlayingSidebarPage` | `NowPlayingSidebarPage?` | Now Playing sidebar page (`nil` = hidden) |

**Key Methods**:
- `play(videoId:)` — Loads and plays a video
- `play(song:)` — Plays a Song model
- `confirmPlaybackStarted()` — Dismisses mini player

### SingletonPlayerWebView

**File**: `Sources/Kaset/Views/MiniPlayerWebView.swift`

Manages the singleton WebView for playback:

- Creates exactly ONE WebView for app lifetime
- Handles video loading with pause-before-load
- JavaScript bridge for playback state updates
- Survives window close for background audio
- Is **re-parented** into whichever window shows it, so exactly one window may host it at a time — see `PlayerSurfaceHost` and [ADR-0031](adr/0031-window-model-and-player-surface-ownership.md)

```swift
@MainActor
final class SingletonPlayerWebView {
    static let shared = SingletonPlayerWebView()

    func getWebView(webKitManager:, playerService:) -> WKWebView
    func loadVideo(videoId: String)
}
```

### NowPlayingManager

**File**: `Sources/Kaset/Services/Player/NowPlayingManager.swift`

Remote command center integration for media key support:

- Registers `MPRemoteCommandCenter` handlers
- Handles media keys (play/pause, next, previous, seek)
- Routes commands to `PlayerService` → `SingletonPlayerWebView`

**Note**: Now Playing display (track info, album art) is handled natively by WKWebView's Media Session API. This provides better integration with album artwork from YouTube Music.

### HapticService

**File**: `Sources/Kaset/Services/HapticService.swift`

Provides tactile feedback on Macs with Force Touch trackpads:

| Feedback Type | Pattern | Used For |
|---------------|---------|----------|
| `.playbackAction` | `.generic` | Play, pause, skip |
| `.toggle` | `.alignment` | Shuffle, repeat, like/dislike |
| `.sliderBoundary` | `.levelChange` | Volume/seek at 0% or 100% |
| `.navigation` | `.alignment` | Sidebar selection |
| `.success` | `.generic` | Add to library, search submit |
| `.error` | `.generic` | Action failures |

**Accessibility**: Respects user preference (Settings → General) and system "Reduce Motion" setting.

### FavoritesManager

**File**: `Sources/Kaset/Services/FavoritesManager.swift`

Manages user-curated Favorites section on Home view:

| Property | Type | Description |
|----------|------|-------------|
| `items` | `[FavoriteItem]` | Ordered list of pinned items |
| `isVisible` | `Bool` | `true` when items exist |

**Supported Item Types**: Song, Album, Playlist, Artist

**Key Methods**:
- `add(_:)` — Adds item to front of list (no duplicates)
- `remove(contentId:)` — Removes by videoId/browseId
- `toggle(_:)` — Adds if not pinned, removes if pinned
- `move(from:to:)` — Reorders via drag-and-drop
- `isPinned(contentId:)` — Checks if item is in Favorites

**Persistence**:
- **Location**: `~/Library/Application Support/Kaset/favorites.json`
- **Format**: JSON-encoded `[FavoriteItem]`
- **Writes**: Async on background thread via `Task.detached`
- **Reads**: Synchronous at init (one-time on app launch)

**Related Files**:
- `Sources/Kaset/Models/FavoriteItem.swift` — Data model with `ItemType` enum
- `Sources/Kaset/Views/SharedViews/FavoritesSection.swift` — Horizontal scrolling UI
- `Sources/Kaset/Views/SharedViews/FavoritesContextMenu.swift` — Shared context menu items

### NotificationService

**File**: `Sources/Kaset/Services/Notification/NotificationService.swift`

Posts local notifications when the current track changes:

- Observes `PlayerService.currentTrack` for changes
- Posts silent alerts with track title and artist
- Respects user preference via `SettingsManager.showNowPlayingNotifications`
- Requests notification authorization on init

**Usage**: Instantiated in `MainWindow` and kept alive for app lifetime.

### NetworkMonitor

**File**: `Sources/Kaset/Services/NetworkMonitor.swift`

Monitors network connectivity using `NWPathMonitor`:

| Property | Type | Description |
|----------|------|-------------|
| `isConnected` | `Bool` | Whether network is available |
| `isExpensive` | `Bool` | Cellular or hotspot connection |
| `isConstrained` | `Bool` | Low Data Mode enabled |
| `interfaceType` | `InterfaceType` | WiFi, cellular, wired, etc. |
| `statusDescription` | `String` | Human-readable status |

**Note**: Uses `DispatchQueue` for `NWPathMonitor` callbacks (no async/await API from Apple).

### SettingsManager

**File**: `Sources/Kaset/Services/SettingsManager.swift`

Manages user preferences persisted via `UserDefaults`:

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `showNowPlayingNotifications` | `Bool` | `true` | Track change notifications |
| `defaultLaunchPage` | `LaunchPage` | `.home` | Initial page on app launch |
| `hapticFeedbackEnabled` | `Bool` | `true` | Force Touch feedback |
| `rememberPlaybackSettings` | `Bool` | `false` | Persist shuffle/repeat state |
| `syncedLyricsEnabled` | `Bool` | `true` | Enable synced lyrics provider lookup before plain lyrics fallback |
| `lyricsProviderOrder` | `[LyricsProviderID]` | BetterLyrics, Paxsenix, Unison, KuGo, LRCLIB | Priority order for lyrics providers |
| `disabledLyricsProviders` | `Set<LyricsProviderID>` | `[]` | Providers switched off in Lyrics settings |

**Lyrics Providers** are configured per-provider in the dedicated **Lyrics** settings tab (`LyricsSettingsView`): each source can be toggled independently and dragged to set priority. A hidden **Provider Status** card probes each provider's host and shows a red/green LED. The legacy single-choice preset (`settings.lyricsProvider`) is migrated into this model on first launch.

**LaunchPage Options**: Home, Explore, Charts, Moods & Genres, New Releases, Liked Music, Playlists, Last Used

### SyncedLyricsService

**File**: `Sources/Kaset/Services/Lyrics/SyncedLyricsService.swift`

Coordinates synced and plain lyrics resolution for the current track:

| Property | Type | Description |
|----------|------|-------------|
| `currentLyrics` | `LyricResult` | Currently displayed `.synced`, `.plain`, or `.unavailable` lyrics |
| `activeProvider` | `String?` | Provider/source label surfaced in the lyrics UI |
| `availableLyricsVariants` | `[LyricsVariant]` | Alternative community versions for the current track (memory-only) |
| `selectedLyricsVariantID` | `String?` | Which version is on screen, when a variant list exists |
| `isLoading` | `Bool` | Whether synced provider search is currently running |

**Key Behaviors**:
- Searches all enabled `LyricsProvider` implementations concurrently using `LyricsSearchInfo`; the enabled set and its priority come from `SettingsManager`
- Ships with `BetterLyricsProvider`, `PaxsenixProvider`, `UnisonProvider`, `KuGoProvider`, and `LRCLibProvider`; the highest-fidelity result across them wins (word > line > plain). When BetterLyrics only has unsynced lyrics it serves a TTML document with no timing; the provider returns that as `.plain` rather than "no lyrics".
- Caches results in memory by `videoId` and can upgrade cached plain lyrics when synced lyrics become available later
- Persists each resolved result to one file per song via `LyricsCacheStore` (`~/Library/Application Support/Kaset/LyricsCache/<videoId>.json`) when a store is injected
- Resolves the real home directory (via `getpwuid`) instead of the sandbox container; `Kaset.entitlements` grants the sandboxed app a home-relative temporary exception for `~/Library/Application Support/Kaset/`
- Migrates a legacy single-file lyrics cache (`~/Library/Application Support/Kaset/lyrics-cache.json`) into per-song files in the background on launch
- Uses `fetchGeneration` to ignore stale async completions when the user changes tracks quickly
- Preserves plain lyrics fallback state until a higher-quality synced result is resolved
- Credits community submitters via `LyricsAttribution` (name, profile URL, avatar) and, when a winning `LyricsVariantProvider` (Unison) offers more than one version, loads its alternatives so the lyrics footer can switch between them; the chosen version becomes the cached result
- The submitter credit renders at the end of the lyric sheet (never pinned over the lyrics); the sticky footer carries only `Source:` and the version picker
- Models backing vocals: `TimedWord.isBackground` and `SyncedLyricLine.backgroundWords` keep `ttm:role="x-bg"` (and Paxsenix `background`) phrases out of the lead line, so the lead text is never glued to a backing phrase and the karaoke fill is not dragged backwards. Backing vocals animate with the same per-character karaoke wipe as the lead — `KaraokeFillModel.backgroundWords(for:)` builds their fill windows from their own onsets, both lines render from the one display clock inside `KaraokeTimeSource`, and `KaraokeLayoutCache` keys by (line, font size, lead-or-backing) so a row's two layouts never evict each other. Instrumental interludes become pause-dot rows: providers leave them implicit as a **gap between consecutive lines** rather than as an empty line — word-synced TTML has no empty paragraphs at all — so `SyncedLyrics.withPauseInterludes(minimumGapMs:)`, applied once in `SyncedLyricsService.apply`, inserts a row spanning each gap of 600 ms or more. The three dots' bounce is timed by the interlude rather than by a clock of its own (`SyncedLyrics.PauseInterlude.dotLift`, served as `SyncedLyrics.PauseDots`): each dot's turn holds a whole number of bounces sized so one takes about 750 ms, so the dot is at rest at both ends of its turn and never appears mid-air, whatever the gap is — a 600 ms one gets a single quick pulse and a half-minute one does not flutter. See [ADR-0025](adr/0025-background-vocals.md)

**Related Files**:
- `Sources/Kaset/Services/Lyrics/LyricsProvider.swift` — Provider protocol and search model
- `Sources/Kaset/Services/Lyrics/LyricsProviderStatusService.swift` — Host reachability probe for the status card
- `Sources/Kaset/Views/LyricsSettingsView.swift` — Lyrics settings tab (toggles, priority, status card)
- `Sources/Kaset/Services/Lyrics/Providers/BetterLyricsProvider.swift` — Apple Music TTML via `lyrics-api.boidu.dev`
- `Sources/Kaset/Services/Lyrics/Providers/PaxsenixProvider.swift` — Apple Music TTML/LRC via `lyrics.paxsenix.org`
- `Sources/Kaset/Services/Lyrics/Providers/UnisonProvider.swift` — Community TTML/LRC via `unison.boidu.dev`
- `Sources/Kaset/Services/Lyrics/Providers/KuGoProvider.swift` — Line-synced LRC via KuGou
- `Sources/Kaset/Services/Lyrics/Providers/LRCLibProvider.swift` — External synced lyrics provider
- `Sources/Kaset/Services/API/Parsers/LRCParser.swift` — LRC to `SyncedLyrics` parser
- `Sources/Kaset/Services/API/Parsers/TTMLParser.swift` — Apple Music TTML to `SyncedLyrics` (and untimed TTML to plain `Lyrics`) parser

**Integration**: Created once in `KasetApp` and injected through the SwiftUI environment for lyrics views.

See [ADR-0012: Synced Lyrics Provider Architecture](adr/0012-synced-lyrics-architecture.md) for design details.
See [ADR-0018: Karaoke Lyrics Animation](adr/0018-karaoke-lyrics-animation.md) for how the display clock, fill model, and renderer turn the 10 Hz playback samples into the word-by-word wipe.

### ShareService

**File**: `Sources/Kaset/Services/ShareService.swift`

Provides share sheet functionality via the `Shareable` protocol:

```swift
protocol Shareable {
    var shareTitle: String { get }
    var shareSubtitle: String? { get }
    var shareURL: URL? { get }
}
```

**Conforming Types**: `Song`, `Playlist`, `Album`, `Artist`

**Share Text Format**: "Title by Artist" or just "Title" for artists.

### SongLikeStatusManager

**File**: `Sources/Kaset/Services/SongLikeStatusManager.swift`

Caches and syncs like/dislike status for songs:

| Method | Description |
|--------|-------------|
| `status(for:)` | Get cached status for video ID or Song |
| `isLiked(_:)` | Check if song is liked |
| `setStatus(_:for:)` | Update cache (optimistic update) |
| `rate(_:status:)` | Sync rating with YouTube Music API |

**Optimistic Updates**: Updates cache immediately, rolls back on API failure.

### URLHandler

**File**: `Sources/Kaset/Services/URLHandler.swift`

Parses YouTube Music and custom `kaset://` URLs:

| URL Pattern | ParsedContent |
|-------------|---------------|
| `music.youtube.com/watch?v=xxx` | `.song(videoId:)` |
| `music.youtube.com/playlist?list=xxx` | `.playlist(id:)` |
| `music.youtube.com/browse/MPRExxx` | `.album(id:)` |
| `music.youtube.com/channel/UCxxx` | `.artist(id:)` |
| `kaset://play?v=xxx` | `.song(videoId:)` |
| `kaset://playlist?list=xxx` | `.playlist(id:)` |
| `kaset://album?id=xxx` | `.album(id:)` |
| `kaset://artist?id=xxx` | `.artist(id:)` |

**Usage**: Called from `AppDelegate.application(_:open:)` to handle deep links (it was the `Window` scene's `.onOpenURL`; see [ADR-0030](adr/0030-appkit-window-shell.md) for why the main window is AppKit's now).

### ScriptCommands (AppleScript)

**File**: `Sources/Kaset/Services/Scripting/ScriptCommands.swift`

Provides AppleScript support for external automation via NSScriptCommand subclasses:

| Command Class | AppleScript Command | Description |
|---------------|---------------------|-------------|
| `PlayCommand` | `play` | Resume playback |
| `PauseCommand` | `pause` | Pause playback |
| `PlayPauseCommand` | `playpause` | Toggle play/pause |
| `NextTrackCommand` | `next track` | Skip to next track |
| `PreviousTrackCommand` | `previous track` | Go to previous track |
| `SetVolumeCommand` | `set volume N` | Set volume (0-100) |
| `ToggleMuteCommand` | `toggle mute` | Toggle mute state |
| `ToggleShuffleCommand` | `toggle shuffle` | Toggle shuffle mode |
| `CycleRepeatCommand` | `cycle repeat` | Cycle repeat (Off → All → One) |
| `LikeTrackCommand` | `like track` | Like current track |
| `DislikeTrackCommand` | `dislike track` | Dislike current track |
| `GetPlayerInfoCommand` | `get player info` | Returns player state as JSON |

**Implementation Details**:

- Commands access `PlayerService.shared` via `MainActor.assumeIsolated` (AppleScript runs on main thread)
- Synchronous methods (shuffle, repeat, like/dislike) execute directly
- Async methods (play, pause, volume) spawn detached Tasks
- All commands return AppleScript errors (`-1728`) if `PlayerService.shared` is nil
- Logging via `DiagnosticsLogger.scripting`

**Related Files**:
- `Sources/Kaset/Kaset.sdef` — AppleScript dictionary definition
- `Sources/Kaset/Info.plist` — `NSAppleScriptEnabled` and `OSAScriptingDefinition` keys

**Usage**:
```applescript
tell application "Kaset"
    play
    set volume 50
    get player info  -- Returns JSON string
end tell
```

### UpdaterService

**File**: `Sources/Kaset/Services/UpdaterService.swift`

Manages application updates via Sparkle framework:

| Property | Type | Description |
|----------|------|-------------|
| `automaticChecksEnabled` | `Bool` | Auto-check on launch |
| `canCheckForUpdates` | `Bool` | Whether check is allowed now |

**Key Methods**:
- `checkForUpdates()` — Manually trigger update check

See [ADR-0007: Sparkle Auto-Updates](adr/0007-sparkle-auto-updates.md) for design details.

### AppDelegate

**File**: `Sources/Kaset/AppDelegate.swift`

Application lifecycle management:

- **Creates and owns the app's main window** (`installMainWindow()`): an `NSWindow` with `MainWindow` as its `NSHostingController`'s root view, the app's chrome, a `KasetMainWindow` autosave name, and no SwiftUI window controller behind it — which is what leaves the window's toolbar to the app ([ADR-0030](adr/0030-appkit-window-shell.md)). The view comes from `KasetApp.makeRootView()`, handed over in `KasetApp.init`
- Because that handover happens in `init`, `KasetApp` holds its services as **plain stored properties** and the window's UI state in an `@Observable` `AppWindowState`: a `@State` read outside a view/scene body is not a read (SwiftUI returns a constant binding and a fresh instance per read), which broke the navigation sidebar's selection and left `MainWindow` on its initializing branch — and therefore without a toolbar — until it was removed
- Is the app's URL entry point (`application(_:open:)`), since there is no `Window` scene carrying `.onOpenURL`
- **Owns every window the app makes** ([ADR-0031](adr/0031-window-model-and-player-surface-ownership.md)): the main window, and the detached mini player panel (`showMiniPlayerPanel()` / `closeMiniPlayerPanel()`), which moves the shared player surface between the two. Windows are AppKit's when they have to outlive a scene, be found by the app, or carry an app-owned toolbar; `Settings` stays a SwiftUI scene because nothing else needs to know about it
- Implements `NSWindowDelegate` to hide window instead of close
- Keeps app running when window is closed (`applicationShouldTerminateAfterLastWindowClosed` returns `false`)
- Handles dock icon click to reopen window

### CastService

**File**: `Sources/Kaset/Services/Cast/CastService.swift`

Streams Kaset's audio to a Google Cast device. Kaset stays the player: the audio the WebView decodes is
tapped, encoded, and served to the device's built-in Default Media Receiver. See
[ADR-0015](adr/0015-chromecast-audio-casting.md) for the design and [docs/playback.md](playback.md#google-cast)
for the pipeline.

| Property | Type | Description |
|----------|------|-------------|
| `state` | `State` | `idle`, `searching`, `connecting`, `casting`, or `failed` |
| `devices` | `[CastDevice]` | Cast devices visible on the network |
| `isCasting` | `Bool` | Whether audio is being streamed to a device |
| `isReceiverConnected` | `Bool` | Whether the device is reading the audio stream |
| `activeDevice` | `CastDevice?` | Device being connected to or cast to |

Supporting types: `CastDeviceDiscovery` (mDNS), `CastConnection` and `CastReceiverSession` (CASTV2),
`AudioProcessTap` and `AACStreamEncoder` (capture and encode), `LocalAudioStreamServer` (HTTP stream).

**Note**: `LocalAudioStreamServer` uses `DispatchQueue` for `NWListener` callbacks, since Network framework
has no async/await entry points.

## Authentication Flow

```
App Launch
    │
    ▼
┌─────────────────┐
│ Check cookies   │──── __Secure-3PAPISID exists? ────┐
│ in WebKitManager│                                    │
└─────────────────┘                                    │
    │ No                                               │ Yes
    ▼                                                  ▼
┌─────────────────┐                          ┌─────────────────┐
│ Show LoginSheet │                          │ AuthService     │
│ (WKWebView)     │                          │ .loggedIn       │
└─────────────────┘                          └─────────────────┘
    │
    │ User signs in → cookies set
    │
    ▼
┌─────────────────┐
│ Observer fires  │
│ cookiesDidChange│
└─────────────────┘
    │
    ▼
┌─────────────────┐
│ Extract SAPISID │
│ Dismiss sheet   │
└─────────────────┘
```

## API Request Flow

```
YTMusicClient.getHome()
    │
    ▼
┌─────────────────────────────────────────────────┐
│ buildAuthHeaders()                              │
│  1. Get cookies from WebKitManager              │
│  2. Extract __Secure-3PAPISID                   │
│  3. Compute SAPISIDHASH = ts_SHA1(ts+sapi+origin)│
│  4. Build Cookie, Authorization, Origin headers │
└─────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────┐
│ POST https://music.youtube.com/youtubei/v1/browse│
│ Body: { context: { client: WEB_REMIX }, ... }   │
└─────────────────────────────────────────────────┘
    │
    ├── 200 OK → Parse JSON → Return HomeResponse
    │
    └── 401/403 → Throw YTMusicError.authExpired
                  → AuthService.sessionExpired()
                  → Show LoginSheet
```

## Playback Flow

```
User clicks Play
    │
    ▼
┌─────────────────────────────────────────────────┐
│ PlayerService.play(videoId:)                    │
│  → Sets pendingPlayVideoId                      │
│  → Shows mini player toast                      │
└─────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────┐
│ PersistentPlayerView appears                    │
│  → Gets singleton WebView                       │
│  → Loads music.youtube.com/watch?v={videoId}    │
└─────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────┐
│ WKWebView plays audio (DRM handled by WebKit)   │
│  → JS bridge sends STATE_UPDATE messages        │
│  → PlayerService updates isPlaying, progress    │
└─────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────┐
│ WKWebView Media Session (native)                │
│  → Updates macOS Now Playing (with album art)   │
│ NowPlayingManager                               │
│  → Registers media key handlers → PlayerService │
└─────────────────────────────────────────────────┘
```

## Background Audio Flow

```
User closes window (⌘W or red button)
    │
    ▼
┌─────────────────────────────────────────────────┐
│ AppDelegate.windowShouldClose(_:)               │
│  → Returns false (prevents close)               │
│  → Hides window instead                         │
└─────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────┐
│ WebView remains alive (in singleton)            │
│  → Audio continues playing                      │
│  → Media keys still work                        │
└─────────────────────────────────────────────────┘
    │
    │ User clicks dock icon
    ▼
┌─────────────────────────────────────────────────┐
│ AppDelegate.applicationShouldHandleReopen       │
│  → Shows hidden window                          │
│  → Same WebView still playing                   │
└─────────────────────────────────────────────────┘
    │
    │ User quits (⌘Q)
    ▼
┌─────────────────────────────────────────────────┐
│ App terminates                                  │
│  → WebView destroyed → Audio stops              │
└─────────────────────────────────────────────────┘
```

## Error Handling

### YTMusicError

**File**: `Sources/Kaset/Models/YTMusicError.swift`

Unified error type for the app:

| Error | Description |
|-------|-------------|
| `.authExpired` | Session invalid (401/403) |
| `.notAuthenticated` | No valid session |
| `.networkError` | Connection failed |
| `.parseError` | JSON decoding failed |
| `.apiError` | API returned error with code |
| `.playbackError` | Playback-related failure |
| `.unknown` | Generic error |

### Error Flow

1. API returns 401/403 → `YTMusicClient` throws `.authExpired`
2. `AuthService.sessionExpired()` called → state becomes `.loggedOut`
3. `AuthService.needsReauth` set to `true`
4. `MainWindow` observes and presents `LoginSheet`
5. User re-authenticates → sheet dismissed, view reloads

## Logging

All services log via `DiagnosticsLogger`:

```swift
DiagnosticsLogger.player.info("Loading video: \(videoId)")
DiagnosticsLogger.auth.error("Cookie extraction failed")
```

**Categories**: `.player`, `.auth`, `.api`, `.webKit`, `.haptic`, `.notification`, `.scripting`

**Levels**: `.debug`, `.info`, `.warning`, `.error`

## Utilities

The `Sources/Kaset/Utilities/` folder contains shared helper components.

### ImageCache

**File**: `Sources/Kaset/Utilities/ImageCache.swift`

Thread-safe actor with memory and disk caching:

| Feature | Description |
|---------|-------------|
| Memory cache | 200 items, 50MB limit via `NSCache` |
| Disk cache | 200MB limit with LRU eviction |
| Downsampling | Images resized to display size before caching |
| Prefetch | Structured cancellation for SwiftUI `.task` lifecycle |

**Key Methods**:
- `image(for:targetSize:)` — Fetch and cache image
- `prefetch(urls:targetSize:maxConcurrent:)` — Batch prefetch for lists

### ColorExtractor

**File**: `Sources/Kaset/Utilities/ColorExtractor.swift`

Extracts dominant colors from album art for dynamic theming:

- Uses `CIAreaAverage` filter for color extraction
- Caches extracted colors to avoid repeated processing
- Used by `AccentBackground` for gradient overlays

### AnimationConfiguration

**File**: `Sources/Kaset/Utilities/AnimationConfiguration.swift`

Standardized animation timing for consistent motion design:

| Animation | Duration | Curve | Used For |
|-----------|----------|-------|----------|
| `.standard` | 0.25s | `.easeInOut` | General transitions |
| `.quick` | 0.15s | `.easeOut` | Button feedback |
| `.slow` | 0.4s | `.easeInOut` | Panel reveals |

### AccessibilityIdentifiers

**File**: `Sources/Kaset/Utilities/AccessibilityIdentifiers.swift`

Centralized UI test identifiers organized by feature:

```swift
enum AccessibilityID {
    enum Player { static let playButton = "player.playButton" }
    enum Queue { static let container = "queue.container" }
    // ...
}
```

**Benefits**: Prevents string duplication, enables IDE autocomplete in tests.

### IntelligenceModifier

**File**: `Sources/Kaset/Utilities/IntelligenceModifier.swift`

SwiftUI modifier to hide AI features when unavailable:

```swift
.requiresIntelligence()  // Hides view if Apple Intelligence unavailable
```

Checks `FoundationModelsService.shared.isAvailable` and applies opacity/disabled state.

### RetryPolicy

**File**: `Sources/Kaset/Utilities/RetryPolicy.swift`

Exponential backoff for network retries:

```swift
try await RetryPolicy.execute(
    maxAttempts: 3,
    initialDelay: .seconds(1),
    shouldRetry: { ($0 as? YTMusicError)?.isRetryable ?? false }
) {
    try await client.fetchData()
}
```

## Performance Guidelines

This section documents performance patterns and optimizations used throughout the codebase.

### Network Optimization

**File**: `Sources/Kaset/Services/API/YTMusicClient.swift`

The API client uses an optimized `URLSession` configuration:

```swift
let configuration = URLSessionConfiguration.default
configuration.httpMaximumConnectionsPerHost = 6   // Connection pool size (HTTP/2 multiplexing is automatic)
configuration.urlCache = URLCache.shared          // HTTP caching
configuration.timeoutIntervalForRequest = 15      // Fail fast
```

### API Caching

**File**: `Sources/Kaset/Services/API/APICache.swift`

In-memory cache with TTL and LRU eviction:

| TTL | Endpoints |
|-----|-----------|
| 5 minutes | Home, Explore, Library |
| 2 minutes | Search |
| 30 minutes | Playlist, Song metadata |
| 1 hour | Artist |
| 24 hours | Lyrics |

**Design**:
- Pre-allocated dictionary capacity to reduce rehashing
- Periodic eviction (every 30 seconds) instead of per-write
- Stable cache keys using SHA256 hash of sorted JSON body

### Image Caching

**File**: `Sources/Kaset/Utilities/ImageCache.swift`

Thread-safe actor with memory and disk caching:

| Feature | Description |
|---------|-------------|
| Memory cache | 200 items, 50MB limit via `NSCache` |
| Disk cache | 200MB limit with LRU eviction |
| Downsampling | Images resized to display size before caching |
| Structured cancellation | Prefetch respects SwiftUI `.task` cancellation |

**Prefetch Pattern**:
```swift
// In view's .task modifier - cancellation is automatic when view disappears
await ImageCache.shared.prefetch(
    urls: section.items.prefix(10).compactMap { $0.thumbnailURL },
    targetSize: CGSize(width: 160, height: 160),
    maxConcurrent: 4
)
```

### SwiftUI View Optimization

#### Stable ForEach Identity

**Avoid** creating new array identity on every render:

```swift
// ❌ Bad: Array(enumerated()) creates new array identity
ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
    Row(item)
}

// ✅ Good: Direct iteration with stable id
ForEach(items) { item in
    Row(item)
}

// ✅ Good: Enumeration only when rank is needed (charts)
ForEach(Array(chartItems.enumerated()), id: \.element.id) { index, item in
    ChartRow(item, rank: index + 1)
}
```

#### Throttled UI Updates

For frequently changing values (e.g., playback progress at 60Hz), cache formatted strings:

```swift
// In PlayerBar
@State private var formattedProgress: String = "0:00"
@State private var lastProgressSecond: Int = -1

.onChange(of: playerService.progress) { _, newValue in
    let currentSecond = Int(newValue)
    if currentSecond != lastProgressSecond {
        lastProgressSecond = currentSecond
        formattedProgress = formatTime(newValue)  // Only 1x per second
    }
}
```

#### Task Cancellation

Cancel async work when views disappear or inputs change:

```swift
// In CachedAsyncImage
@State private var loadTask: Task<Void, Never>?

.task(id: url) {
    loadTask?.cancel()
    loadTask = Task {
        guard !Task.isCancelled else { return }
        image = await ImageCache.shared.image(for: url)
    }
}
.onDisappear {
    loadTask?.cancel()
}
```

### Memory Management

- **NSCache** for images responds to memory pressure automatically
- `DispatchSource.makeMemoryPressureSource` clears image cache on system warning
- Prefetch tasks are cancellable to prevent memory buildup during fast scrolling

### Profiling Checklist

Before completing non-trivial features, verify:

- [ ] No `await` calls inside loops or `ForEach`
- [ ] Long, scroll-critical lists of rich rows use `List`, not `ScrollView` + `LazyVStack`:
      a `LazyVStack` re-measures and re-renders the whole realised page every scroll frame, so
      scroll cost scales with each row's view-tree size — see [adr/0014](adr/0014-playlist-scroll-performance.md)
- [ ] Network calls cancelled on view disappear (`.task` handles this)
- [ ] Parsers have `measure {}` tests if processing large payloads
- [ ] Images use `ImageCache` with appropriate `targetSize`
- [ ] Search input is debounced (not firing on every keystroke)
- [ ] ForEach uses stable identity (avoid `Array(enumerated())` unless needed)
- [ ] Large lists use their own row view (not inline row builders in the parent body) so a
      parent update doesn't rebuild every visible row — see [adr/0014](adr/0014-playlist-scroll-performance.md)
- [ ] Rich rows in a `List` draw their highlight **full-bleed** at row level (zero
      `listRowInsets` + an internal content inset). Right-clicking a row makes SwiftUI decorate
      the whole row — full-width fill plus a 2 pt accent outline — and that decoration cannot be
      removed (`selectionHighlightStyle = .none`, `focusRingType = .none` on the table/row/cell
      views, `deselectAll` and `.focusEffectDisabled()` all leave it in place). A highlight that
      is inset and rounded disagrees with it, so the row's own highlight has to occupy the same
      rectangle (see [adr/0014](adr/0014-playlist-scroll-performance.md))

## UI Design (macOS 26+)

The app uses Apple's **Liquid Glass** design language introduced in macOS 26.

### Glass Effect Patterns

| Component | Glass Pattern |
|-----------|---------------|
| `PlayerBar` | `.glassEffect(.regular.interactive(), in: .capsule)` |
| `Sidebar` | AppKit's `sidebarWithViewController:` material (no hand-rolled effect view) |
| `FullscreenPodcastView` top bar | `GlassEffectContainer` + `.glassEffect(.regular.interactive(), in: .circle)` (close, transcript toggle) and `.capsule` (volume) |
| `QueueView` / `LyricsView` | `.glassEffectTransition(.materialize)` |
| Search field | `.glassEffect(.regular, in: .capsule)` |
| Search suggestions | `.glassEffect(.regular, in: .rect(cornerRadius: 8))` |

### Glass Effect Best Practices

1. **Use `GlassEffectContainer`** to wrap multiple glass elements
2. **Use `.glassEffectTransition(.materialize)`** for panels that appear/disappear
3. **Use `@Namespace` + `.glassEffectID()`** for morphing between states
4. **Avoid glass-on-glass** — don't apply `.buttonStyle(.glass)` to buttons already inside a glass container
5. **Reserve glass for navigation/floating controls** — not for content areas

## Foundation Models (Apple Intelligence)

Kaset integrates Apple's on-device Foundation Models framework for AI-powered features. See [ADR-0005: Foundation Models Architecture](adr/0005-foundation-models-architecture.md) for detailed design decisions.

### Architecture Overview

```
User Input (natural language)
    │
    ▼
┌─────────────────────────────────────────────────┐
│ FoundationModelsService                         │
│  → Check availability                           │
│  → Create session with tools                    │
└─────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────┐
│ LanguageModelSession                            │
│  → Parse input to @Generable type               │
│  → Call tools for grounded data                 │
│  → Return structured response                   │
└─────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────┐
│ Execute Action                                  │
│  → MusicIntent → PlayerService                  │
│  → QueueIntent → PlayerService queue methods    │
│  → LyricsSummary → Display in UI                │
└─────────────────────────────────────────────────┘
```

### Key Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `FoundationModelsService` | `Sources/Kaset/Services/AI/` | Singleton managing AI availability and sessions |
| `@Generable` Models | `Sources/Kaset/Models/AI/` | Type-safe structured outputs (`MusicIntent`, `LyricsSummary`, etc.) |
| Tools | `Sources/Kaset/Services/AI/Tools/` | Ground AI responses in real catalog data |
| `AIErrorHandler` | `Sources/Kaset/Services/AI/` | User-friendly error messages |
| `RequiresIntelligenceModifier` | `Sources/Kaset/Utilities/` | Hide AI features when unavailable |

### AI Tools

Tools ground AI responses in real data from the YouTube Music catalog, preventing hallucination.

**MusicSearchTool** (`Sources/Kaset/Services/AI/Tools/MusicSearchTool.swift`)

Searches the YouTube Music catalog for songs, artists, and albums:

```swift
@Generable
struct MusicSearchResult {
    let songs: [SongResult]
    let artists: [ArtistResult]
    let albums: [AlbumResult]
}
```

**QueueTool** (`Sources/Kaset/Services/AI/Tools/QueueTool.swift`)

Provides access to the current playback queue for AI-driven queue management:

- Returns current queue contents
- Used by `QueueIntent` for natural language queue manipulation
- Enables commands like "remove duplicates" or "play upbeat songs next"

### @Generable Models

Type-safe structured outputs for AI responses:

| Model | File | Purpose |
|-------|------|---------|
| `MusicIntent` | `Sources/Kaset/Models/AI/MusicIntent.swift` | Parsed user commands (play, pause, search, etc.) |
| `LyricsSummary` | `Sources/Kaset/Models/AI/LyricsSummary.swift` | Lyrics explanation with themes and mood |
| `PlaylistChanges` | `Sources/Kaset/Models/AI/PlaylistChanges.swift` | Queue refinement operations |

### AI Features

| Feature | Trigger | Model Used |
|---------|---------|------------|
| Command Bar | ⌘K | `MusicIntent`, `MusicQuery` |
| Lyrics Explanation | "Explain" button in lyrics view | `LyricsSummary` |
| Queue Management | Natural language in command bar | `QueueIntent` |
| Queue Refinement | Refine button in queue view | `QueueChanges` |

### Best Practices

1. **Token Limit**: 4,096 tokens per session. Chunk large playlists, truncate long lyrics.
2. **Streaming**: Use `streamResponse` for long-form content (lyrics explanation).
3. **Tools**: Always use tools to ground responses in real data—prevents hallucination.
4. **Graceful Degradation**: Use `.requiresIntelligence()` modifier to hide unavailable features.
5. **Error Handling**: Use `AIErrorHandler` for user-friendly messages.

## UI Components

This section documents key SwiftUI views and their integration patterns.

### QueueView

**File**: `Sources/Kaset/Views/QueueView.swift`

Right sidebar panel displaying the playback queue:

- Shows "Up Next" header with shuffle/clear actions
- Displays queue items with drag-to-reorder support
- AI-powered "Refine" button for natural language queue editing
- Uses `.glassEffect(.regular.interactive())` with `.glassEffectTransition(.materialize)`

**Integration**: Toggled via `PlayerService.showQueue`, placed outside `NavigationSplitView` in `MainWindow`.

### LyricsView

**File**: `Sources/Kaset/Views/LyricsView.swift`

Right sidebar panel displaying song lyrics:

- Reads `SyncedLyricsService` from the environment for the current `LyricResult`
- When `SettingsManager.syncedLyricsEnabled` is enabled, builds `LyricsSearchInfo` from the active track and requests synced lyrics first
- Falls back to `YTMusicClient.getLyrics(videoId:)` for plain YouTube Music lyrics when synced providers return `.unavailable`
- Starts 10 Hz WebView playback polling only while rendering `.synced` lyrics so line highlighting stays aligned without constant idle polling
- `SyncedLyricsDisplayView` auto-centers the current line and supports tap-to-seek
- Word-by-word karaoke wipe: `LyricsPlaybackClock` interpolates the 10 Hz samples into a display-rate position (absorbing sample jitter by changing rate, snapping on seeks, freezing on pause), `KaraokeFillModel` turns word timings into per-word fill windows and slices each word's window per character, and `KaraokeLyricsLineView` draws the dim base plus a bright copy masked to the *word's* own fill edge with a feathered glow, so the emphasis travels through a word as the edge does. Only the rows the highlight needs are redrawn per frame, so a line change is continuous; the same view renders the fullscreen lyrics
- The wipe's frame budget is bounded on purpose: each line's words are measured once (`KaraokeLineLayout`, memoized in `KaraokeLayoutCache`) so a frame is arithmetic on known widths, a word's text is drawn as **one run cut by a mask** rather than a run per character (a settled word is a single layer, and only the character the edge is crossing is cut out of the word and drawn again above it — drawing the word as runs at their own origins stepped every character behind the edge by a pixel each time the wave moved), and rows redraw at the rate they need (`KaraokeFrameBudget` — 60 Hz for the line being sung, 30 Hz for a row that is on the clock but is not the one being sung, 10 Hz while the fullscreen player covers the panel, 20 Hz while paused or under Reduce Motion). A settled row draws nothing at all: its `TimelineView` is paused rather than removed
- The line being sung, the line after it *once its own first ramp is approaching* (`armBoundaryMs`, from its lead or backing words — before that it could only redraw the frame it already drew, since a row that has not started renders every word unsung), and the line that has just finished until its own content is settled (`KaraokeFillModel.isLiveRow` / `settleBoundaryMs` — the later of its declared end and the end of its last fill ramp) run on the display clock; every other row is handed a settled position by the *same* `KaraokeTimeSource` timeline, paused in place. The hand-off is therefore a value change in a subtree that keeps its identity rather than a replacement — SwiftUI does not animate a subtree it replaces, and the hand-off lands on the frame the departing line's own departure begins
- Nothing inside a lyric row is a hit-test target (`.allowsHitTesting(false)` on `KaraokeLyricsLineView`): the row owns the tap through its own content shape, and the per-word text layers and the masks cut out of them are otherwise responders that hit testing walks for every mouse move over a redrawing sheet — sampling the running app with the pointer over heavy lyrics puts that walk at the top of the profile, ahead of any drawing
- The highlight moves when the line it is on has finished being sung (`KaraokeFillModel.highlightIndex(in:at:)` — when its content is settled), never `scrollLookaheadMs` earlier: that lead belongs to the *scroll*, which has to arrive before the first word. Letting the emphasis share it made a line start to leave while its last word was still filling
- The character being sung **lifts rather than scales** (`KaraokeCharacter.swell`, while the halo is the *word's* own `glowStrength` — a character's slice of a word's window is far shorter than the halo's rise, so a per-character glow reads as no glow), by a fraction of a pixel at the peak: both envelopes are time-based and reach zero at their own unit's end, because SwiftUI re-rasterizes scaled text every frame (and snaps hardest as it returns to rest — 40 ms before the line ends, in the middle of the line's scale-down, which read as the line jumping in place), and because a glow that vanishes with its unit is a jump too. The lift is what forces the character under the edge to be cut out of the word's text: a translation moves a raster
- Opening the sheet is a settle, not an animation: `settleScroll(using:)` reads the highlight from state (never from the playback time its task captured), repeats an unanimated jump until the lazy stack has materialized the target row (bounded by wall clock, not by iteration count), and holds `isSettling` so no *scroll* animation runs through the sheet's first paint
- A row's emphasis animation is **never conditional**: `isSettling` means only that the sheet is still being put in position. It used to also suppress the rows' emphasis spring to hide the pop-in of the sheet's first highlight, and that window restarts on every lyric-sheet replacement and stretches with main-thread load — so a line change inside it had its scale, opacity and drift applied in a single step, while the words kept animating (the fill is driven by the display clock, not by an implicit animation). The pop-in is gone at its source instead: the sheet seeds its highlight from the playback position it is handed, so the first frame is already correct and there is nothing to suppress (`LyricsEmphasisAnimationTests` renders the real panel in a window and follows the departing line's scaled width frame by frame)
- Lyrics a provider timed only as a whole **appear as a line** at their own start and then stay lit, rather than brightening across the line or faking word timings; they keep the same halo, which blooms in with them and settles
- "Explain" button triggers AI-powered `LyricsSummary` generation for either synced or plain lyrics
- Width: 280px, animated show/hide

**Integration**: Toggled via `PlayerService.showLyrics`, persists across all navigation states, and consumes playback time from `PlayerService.currentTimeMs`.

### WindowShell / WindowShellController

**File**: `Sources/Kaset/Views/WindowShell.swift`

The window's own layout, and the reason the toolbar's items land where a macOS app puts them:

- The window is the app's `NSWindow`, created by `AppDelegate.installMainWindow()` with `MainWindow` as its hosting controller's root view — no SwiftUI `Window` scene, so no SwiftUI window controller is behind the window and nothing but the app touches its toolbar (see [ADR-0030](adr/0030-appkit-window-shell.md))
- One `NSSplitViewController` with three panes — `NSSplitViewItem(sidebarWithViewController:)` for the navigation sidebar, a plain item for the page, `NSSplitViewItem(inspectorWithViewController:)` for the Now Playing column — each hosting SwiftUI; older designs nested a `NavigationSplitView` inside SwiftUI and laid the column beside it in an `HStack`
- Those two *named* items are what AppKit's standard `sidebarTrackingSeparator` / `inspectorTrackingSeparator` items discover and align to, which is what bounds the page's toolbar items by the column's divider (see [ADR-0030](adr/0030-appkit-window-shell.md)); SwiftUI exposes neither the items nor a placement for them
- The panes' backdrops run to the window's top edge (`fullSizeContentView` + a transparent titlebar, set when the app creates the window and re-asserted from `viewDidLayout` when a value differs) while each pane's content still lays out 52pt down, via the pane's own safe area
- That window is a **clear sheet**: `isOpaque = false` and `backgroundColor = .clear`, re-asserted from `viewDidLayout` alongside the rest of the chrome. The navigation sidebar's material is `.behindWindow`, so it needs the desktop behind the window to blur — with the window drawing its own opaque background, the same effect view has only that background to composite against and the column reads as a flat grey sheet. Every *other* pane therefore paints an opaque surface of its own: the page (`MainWindow.contentPane`, a `windowBackgroundColor` background that bleeds up under the toolbar) and the Now Playing column (`NowPlayingSidebarBackground`)
- AppKit owns the divider, its cursor, its clamping, the collapse animation and the width (`autosaveName`); the app states only whether the column is open and the width it opens at the first time, and reads a reader's collapse back off the item
- The **window's minimum width is the panes' own minimums plus the dividers**, never below the 900pt floor the app has always stated (`WindowShellLayout.minimumWindowWidth(tracksColumn:)`, written to the window by `WindowShellController` and stated again on `MainWindow`'s content so the two agree): 967 with the column closed, 1267 with it open. The page is *not* the pane that gives way — a page squeezed below its own minimum is a page whose controls are cut off, and a split view cannot satisfy a requirement larger than its own width, so what AppKit did with the difference was break a constraint and draw the page past the window's edge (`Shell overflow: …` reports it if it ever happens). What gives way instead is how wide a **side pane** may be: each is capped at what is left once the page and the other pane have theirs (`WindowShellLayout.sidebarMaximum` / `inspectorMaximum`). And a window narrower than its minimum is **grown** to it rather than left to crop (once, never shrinking, and never on a reader's divider drag)
- `MainWindow.Layout.pageMinWidth` is the page's own minimum, **765**, measured rather than guessed: with the column open the split view sized itself to 200 + 765 + 300 — each pane at its own floor — and stayed there in a narrower window. The player bar is what needs it (`PlayerBar` lays out its controls in both hover states for exactly this reason)
- The navigation sidebar's surface is AppKit's again: `SidebarMaterialPane` hosts the sidebar's SwiftUI **inside** an `NSVisualEffectView` with the `.sidebar` material at `blendingMode = .behindWindow`, and `Sidebar`'s list hides its own background (`.scrollContentBackground(.hidden)`) — a standalone sidebar list otherwise paints an opaque background over whatever is behind it, so the column read as a flat grey sheet. `.behindWindow` (rather than `.withinWindow`) is what makes it a real macOS sidebar: the material blurs the desktop, the way Finder's and Mail's sidebars do
- The sidebar's rows are **tagged rows, not `NavigationLink`s**: the split view this shell replaced was the navigation container those links belonged to, and a link with no container left to navigate renders its label in the inactive style — the rendered ink measures 0.498 grey against 0.000 for a tagged row, whatever `foregroundStyle` the label is given. The page has always been driven by the list's own `selection` binding, so nothing was lost (`Sidebar.navigationRow(_:)`), and `WindowShell`'s `Sidebar ink:` line measures the rendered result
- The sidebar's content also draws in a **vibrant** appearance, so its labels state literal colours: `.primary` *is* `labelColor`, which `VibrantLight`/`VibrantDark` resolve to a lower-alpha colour (black @ 0.70 against `Aqua`'s 0.85). The appearance cannot be overridden from inside the pane, so `Sidebar.rowForeground(for:)` names the colour — and the icons carry `PackageResourceLookup.brandAccent` while the labels stay neutral, the way Apple Music tints its sidebar glyphs. `SidebarBackingStyleConfigurator` keeps each source-list row's emphasis in step with the window's key state, which is what the row's selection highlight draws with; `Sidebar surface rows:` publishes the appearance and the resolved label colour. The row's **emphasis is also re-stated after every first-responder change** (`Coordinator.repairEmphasis`), because AppKit's own rule is not the app's: the list un-emphasises the selected row the moment it stops being the window's first responder — which a page can cause on a key window by focusing a control of its own — and the highlight then draws in the dimmed, unemphasised style. Measured in the running app with `SearchView`'s focus-on-appear: `rowEmph=true effEmph=true` with a red pill (21609 red pixels) before the page appeared, `rowEmph=false effEmph=false` with a grey one (0 red) after. Both the emphasis rule and the window's key state are facts about a **window**, so the coordinator installs its observations from `BackingView.viewDidMoveToWindow` — `makeNSView`/`updateNSView` run with the view not yet in one, and installing from there left the sidebar observing nothing at all
- `WindowToolbarController` installs the app's own `NSToolbar` (deferred one main-actor turn; a recreated shell controller takes over the toolbar this app already installed, since `NSToolbar.delegate` is weak). Its item list is stated **before** the toolbar goes into the window, so the window is never left with a toolbar that has no items in it. The item list has to be the app's *and* the object has to be the app's, which is why the window is AppKit's: on a SwiftUI-owned window, SwiftUI's window controller rewrote the toolbar's items from its own content every constraint pass, and replacing that toolbar made its `updateToolbarIfNeeded` throw out of `removeObserver:forKeyPath:` inside a constraint pass (`+[NSApplication _crashOnException:]`, `SIGTRAP`)
- The page's **back control is the app's** (`WindowToolbarItem.back`). Taking SwiftUI's toolbar back takes SwiftUI's back button with it — that item (`com.apple.SwiftUI.navigationStack.back`) is the *only* thing SwiftUI's toolbar carried, so a pushed page was left with the page's other controls and no way back: "the other buttons are there but the back button disappears". So a page's stack publishes whether it can be popped, and how (`PageNavigationModel`), through `PageNavigationStack` — a `NavigationStack` that takes the page's own path binding and adds nothing else, so everything that pushes into it is unchanged. The control is drawn only while `canGoBack`, and `goBack()` refuses to run an action that outlived its page
- That control leads the page's region — and to do so, the **window title gives the slot up** (`WindowShellController.applyTitleVisibility`). AppKit draws the title as a flexible view at the *leading* edge of the region right of the sidebar's tracking separator, and lays the region's items out after it, so an item's place in `WindowToolbarItems.identifiers` cannot put it at that edge. Measured in a reproduction of this window (1240pt, the app's item order): with the title visible the first page item sat at x=740, immediately left of the Ask AI button and the page's own controls; with the title hidden it moved to x=224 — the region's leading edge. So the title is hidden while the page has a back control (verified in the running app: the back item renders at x=244, right of the sidebar's divider at ~204–244) and restored when the page is a root. A hidden toolbar is not something the rule un-hides: the fullscreen Now Playing state hides both, and it is `MainWindow.updateWindowTitleVisibility`'s state, not the shell's
- The toolbar is **re-taken** whenever anything else puts its own in the window (`WindowShellController.observeToolbarTakeover`). SwiftUI's window controller does exactly that while pages navigate — it installs its own one-item toolbar as the reader opens an album or a playlist (a page states a `navigationTitle`), and on the way back it takes the toolbar away entirely. The window is then left with a titlebar holding no sidebar toggle, no page controls and no Now Playing toggle — the "the bar on top disappears and the sort/search icons are gone" report — until something re-states the app's, which used to be the next layout or appearance pass. KVO on `NSWindow.toolbar` (there is no notification for it) plus a restored install on the next main-actor turn; each restore is logged (`Toolbar replaced, restoring the app's: …`)

### WindowPageToolbar / PlaylistToolbarControls

**File**: `Sources/Kaset/Views/WindowPageToolbar.swift`

How a page's own controls (search, sort, refresh) get into the window's titlebar, bounded by the Now Playing column's divider:

- The page *publishes* them (`PageToolbarModel.contribute`, retracted by id on disappearance), keyed by page id so the incoming page's publication is not cleared by the outgoing page's retraction
- The window renders the contribution as **one hosted `NSToolbarItem`** (`NSHostingView`, `sizingOptions: [.intrinsicContentSize]`) placed before the inspector tracking separator, and updates it in place as the page changes; the order that puts it there is `WindowToolbarItems.identifiers`, covered by `WindowToolbarTests`
- The hosted controls read the page's model **during a render of the toolbar's tree**, which is what keeps the titlebar field and the page's list in step — so the state they share lives on the model (`PlaylistDetailViewModel.searchText`, `isRefreshing`; `LibraryViewModel`/`HistoryViewModel.isRefreshing`) rather than in the page's `@State`. A manual refresh is a *background* refresh, so `loadingState` cannot say whether one is running: `isRefreshing` is why the flag exists
- Nested pages publish too (`LibraryView` → `PlaylistDetailView`), so the titlebar follows the page on screen rather than the sidebar selection

### NowPlayingSidebarView

**File**: `Sources/Kaset/Views/NowPlayingSidebarView.swift`

The artwork-first right sidebar, the alternative to the two panels above (see [ADR-0029](adr/0029-now-playing-sidebar.md)):

- The window's third pane, laid out by `WindowShell`'s `NSSplitViewController` as an **inspector** item (300–560pt, draggable divider, remembered width) rather than a card floating over the content; see [ADR-0030](adr/0030-appkit-window-shell.md) and `WindowShell.swift`
- The collapse toggle is the window toolbar's last item in **both** states: while the column is closed it is the right-aligned run's trailing control, and while the column is open it is the trailing control of the toolbar's *inspector* region, pushed there by a flexible space (`WindowToolbarItems`) — so it is never drawn on the column. It used to move into the column's top-trailing corner when opened; that put a small glyph in the band the cover art owns, and the column has no interactive view over its backdrop any more. The toolbar item carries an explicit target (the shell's own `toggleInspector(_:)`) rather than `target = nil`
- The navigation sidebar sits on `SidebarMaterialPane` (see `WindowShell`), which hosts it inside AppKit's sidebar material; `Sidebar` no longer wraps its `List` in a `GlassEffectContainer` either, since nothing in it uses a glass effect, and its rows name their own colours because that material puts the content in a vibrant appearance where `labelColor` is dimmed
- The column's contents are sized from the *current* layout, never from a remembered one: `ShellPane` hands the pane's size down from a `GeometryReader` (same layout pass as the frame the divider is moving), and the embedded `QueueSidePanelView` fills its width with its AppKit table sizing its column from the scroll view's own width in `viewDidLayout` — a width passed down from SwiftUI state is one pass behind the divider, which is what made a drag look like the contents were tearing away
- Chosen by `SettingsManager.nowPlayingSidebarEnabled` (off by default); the classic panels stay the default experience and keep their own presentation state. `SettingsManager.nowPlayingSidebarWidth` is only the width the column opens at the first time — `NSSplitView.autosaveName` owns it after that, and the app never writes a width. With the setting on, the column is **open when the app launches** (`PlayerService.init` sets `nowPlayingSidebarPage = .overview`, before the window reads it), so the choice of design is the choice of what the window opens with; the column has a "Nothing playing" state, so it is safe on the transport's first, empty frame
- One column, three pages (`NowPlayingSidebarPage`): the `overview` *is* the column — cover art edge to edge at the top, title and artist under it, a three-line lyric window with the line being sung in the middle, and the next song — and the two sections open `lyrics` (the shared `SyncedLyricsDisplayView` sheet plus `LyricsSourceFooter`) and `queue` (the classic `QueueSidePanelView` with its header and card chrome suppressed)
- The three-line window is that *same* sheet in a 116pt window (`allowsScrolling: false`, faded at the edges), so the karaoke wipe, the emphasis, the pause dots and the centering are the panel's; the empty and loading states are the shared `LyricsStateView`, so both surfaces say the same thing
- The column's background is a blurred copy of the cover (`NowPlayingSidebarBackground`), washing down into the window background and running to the window's top edge: the pane reaches behind the toolbar, so the artwork and its wash are genuinely *behind* the titlebar rather than below it, and both are `.allowsHitTesting(false)` (a `Color` in a background is hit-testable, and an invisible layer over the toolbar band swallowed clicks aimed at what was beneath it); the lyric window and up-next row sit in translucent `NowPlayingSidebarCard` glass so the colours show through
- The artwork crossfades to the track's animated canvas with the fullscreen player's readiness rule (first *rendered* frame, never "item is ready"); `CanvasService` lookups are cache-backed, so the sidebar and the fullscreen player share one lookup per track
- Owns one lyrics lookup on its root so the window and the sheet share it — a page change never looks like a new track and never re-searches

**Integration**: Hosted as the inspector pane of `WindowShell` (see [ADR-0030](adr/0030-appkit-window-shell.md)); shown via `PlayerService.nowPlayingSidebarPage`, and the transport's lyrics/queue buttons and ⌘L follow whichever design is enabled (`isLyricsPanelActive` / `isQueuePanelActive`).

### LyricsSurfaceViews

**File**: `Sources/Kaset/Views/LyricsSurfaceViews.swift`

What every lyric surface says when it has no sheet to draw, shared by `LyricsView` and the Now Playing sidebar so the two cannot drift apart: `LyricsStateView` (loading with the provider being searched, no track, no lyrics — `compact` changes only type size), `LyricsSourceFooter` (provider credit and the community-variant picker) and `LyricsSearchingCaption` (the "still searching" shimmer).

### CommandBarView

**File**: `Sources/Kaset/Views/CommandBarView.swift`

Spotlight-style command palette triggered by ⌘K:

- Natural language input parsed via `MusicIntent`
- Shows suggestions and action previews
- Supports commands: play, pause, skip, search, queue management
- Floating overlay with glass effect

**Trigger**: `@Environment(\.showCommandBar)` environment key.

### ToastView

**File**: `Sources/Kaset/Views/ToastView.swift`

Temporary notification overlay for user feedback:

| Toast Type | Duration | Purpose |
|------------|----------|---------|
| Success | 2s | Action completed (e.g., "Added to library") |
| Error | 3s | Action failed with message |
| Info | 2s | Informational feedback |

**Usage**: Managed via environment or direct state binding.

### SharedViews

**Directory**: `Sources/Kaset/Views/SharedViews/`

Reusable components used across the app:

| Component | Purpose |
|-----------|---------|
| `ErrorView` | Standardized error display with retry button |
| `LoadingView` | Skeleton loading states |
| `SkeletonView` | Shimmer placeholder for loading content |
| `EqualizerView` | Animated bars for "now playing" indicator |
| `HomeSectionItemCard` | Card component for carousel items |
| `InteractiveCardStyle` | Hover/press effects for cards |
| `NavigationDestinationsModifier` | Centralized navigation destination handling |
| `ShareContextMenu` | Context menu for sharing content |
| `StartRadioContextMenu` | Context menu for starting radio/mix |
| `FavoritesSection` | Horizontal scrolling favorites row |
| `FavoritesContextMenu` | Context menu for favorites management |
| `SongActionsHelper` | Common song action handlers |
| `AnimationModifiers` | Reusable animation view modifiers |

### PlayerBar

**File**: `Sources/Kaset/Views/PlayerBar.swift`

A floating capsule-shaped player bar at the bottom of the content area:

```
┌─────────────────────────────────────────────────────────────┐
│  ◀◀  ▶  ▶▶  │  🎵 [Thumbnail] Song Title - Artist  │  🔊━━━ │
└─────────────────────────────────────────────────────────────┘
         ↑                      ↑                        ↑
    Playback              Now Playing              Volume
    Controls               Info                   Control
```

**Implementation**:
```swift
GlassEffectContainer(spacing: 0) {
    HStack {
        playbackControls
        Spacer()
        centerSection  // thumbnail + track info
        Spacer()
        volumeControl
    }
    .glassEffect(.regular.interactive(), in: .capsule)
}
```

**Key Points**:
- Uses `GlassEffectContainer` to wrap glass elements
- `.glassEffect(.regular.interactive(), in: .capsule)` for the liquid glass look
- Only shows functional buttons (no placeholder buttons)
- Thumbnail and track info in center section

### PlayerBar Integration

The `PlayerBar` is added to **every navigable view** via `safeAreaInset`, and the inset belongs *inside*
the page's `NavigationStack` — on the page the stack shows, not on the stack itself:

```swift
// In HomeView, LibraryView, SearchView, PlaylistDetailView
NavigationStack(path: $path) {
    content
        .safeAreaInset(edge: .bottom, spacing: 0) { PlayerBar() }
}
```

**Why not in MainWindow?**
- The shell's content pane shows whichever page the sidebar selects; the pages are what own a stack each
- Views pushed onto a `NavigationStack` don't inherit the parent's `safeAreaInset`
- Each view must explicitly include the `PlayerBar`

**Why inside the stack, and not on it.** An inset applied to the stack belongs to the stack's
*container*, so it outlives a push — and every destination page (`PlaylistDetailView`,
`ArtistDetailView`, `TopSongsView`, …) brings a bar of its own, which then draws a **second** bar
directly above it. That is the "the player bar duplicated, two on top of each other" report, and it
appeared on any push from any page that hosted a stack: Home→album, History→artist, Library→playlist,
Podcasts→show. Inside the stack the bar goes away with the page that owns it.

Measured, both ways, in a reproduction of exactly this arrangement (root bar red, destination bar green,
layer tree drawn to a bitmap and the bar bands counted):

| Inset | After a push |
|-------|--------------|
| on the `NavigationStack` | `green@568 … red@620` — **two bars**, stacked |
| on the stack's root page | `green@568` — one bar |

### Sidebar

**File**: `Sources/Kaset/Views/Sidebar.swift`

Clean, minimal sidebar with only functional navigation:

```
┌──────────────────┐
│ 🔍 Search        │  ← Main navigation
│ 🏠 Home          │
├──────────────────┤
│ Library          │  ← Section header
│ 🎵 Playlists     │  ← Functional items only
└──────────────────┘
```

**Design Principles**:
- Only show items that have implemented functionality
- Remove placeholder items (Artists, Albums, Songs, Liked Songs, etc.)
- Use standard SwiftUI `List` with `.listStyle(.sidebar)`

### Persistent UI Elements

UI elements that must remain visible across all navigation states (like the lyrics sidebar) should be placed **outside** the `NavigationSplitView` hierarchy in `MainWindow`:

```swift
// MainWindow.swift
var mainContent: some View {
    HStack(spacing: 0) {
        NavigationSplitView { ... }  // Sidebar + detail navigation

        // Lyrics sidebar OUTSIDE navigation - persists across all pushed views
        LyricsView(...)
            .frame(width: playerService.showLyrics ? 280 : 0)
    }
}
```

**Why?**
- Views pushed onto a `NavigationStack` replace content *inside* the stack
- If a sidebar is inside the stack, pushed views won't see it
- Placing persistent elements outside the navigation hierarchy ensures they remain visible regardless of navigation state

**Pattern**: Global overlays/sidebars → `MainWindow` level, outside `NavigationSplitView`

### @available Attributes

All UI components require macOS 26.0+ for Liquid Glass:

```swift
@available(macOS 26.0, *)
struct PlayerBar: View { ... }

@available(macOS 26.0, *)
struct MainWindow: View { ... }
```
