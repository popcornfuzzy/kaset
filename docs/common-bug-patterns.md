# Common Bug Patterns to Avoid

These patterns have caused bugs in this codebase. **Always check for these during code review.**

## ❌ Fire-and-Forget Tasks

```swift
// ❌ BAD: Task not tracked, errors lost, can't cancel
func likeTrack() {
    Task { await api.like(trackId) }
}

// ✅ GOOD: Track task, handle errors, support cancellation
private var likeTask: Task<Void, Error>?

func likeTrack() async throws {
    likeTask?.cancel()
    likeTask = Task {
        try await api.like(trackId)
    }
    try await likeTask?.value
}
```

## ❌ Optimistic Updates Without Proper Rollback

```swift
// ❌ BAD: CancellationError not handled, cache permanently wrong
func rate(_ song: Song, status: LikeStatus) async {
    let previous = cache[song.id]
    cache[song.id] = status  // Optimistic update
    do {
        try await api.rate(song.id, status)
    } catch {
        cache[song.id] = previous  // Doesn't run on cancellation!
    }
}

// ✅ GOOD: Handle ALL errors including cancellation
func rate(_ song: Song, status: LikeStatus) async {
    let previous = cache[song.id]
    cache[song.id] = status
    do {
        try await api.rate(song.id, status)
    } catch let error as CancellationError {
        cache[song.id] = previous  // Rollback on cancel
        throw error  // Propagate original cancellation
    } catch {
        cache[song.id] = previous  // Rollback on error
        throw error
    }
}
```

## ❌ Static Shared Singletons with Mutable Assignment

```swift
// ❌ BAD: Race condition if multiple instances created
class LibraryViewModel {
    static var shared: LibraryViewModel?
    init() { Self.shared = self }  // Overwrites previous!
}

// ✅ GOOD: Use SwiftUI Environment for dependency injection
@Observable @MainActor
class LibraryViewModel { /* ... */ }

// In parent view:
.environment(libraryViewModel)

// In child view:
@Environment(LibraryViewModel.self) var viewModel
```

## ❌ `.onAppear` Instead of `.task` for Async Work

```swift
// ❌ BAD: Task not cancelled on disappear, can update stale view
.onAppear {
    Task { await viewModel.load() }
}

// ✅ GOOD: Lifecycle-managed, auto-cancelled on disappear
.task {
    await viewModel.load()
}

// ✅ GOOD: With ID for re-execution on change
.task(id: playlistId) {
    await viewModel.load(playlistId)
}
```

## ❌ ForEach with Unstable Identity

```swift
// ❌ BAD: Index-based identity causes wrong views during mutations
ForEach(tracks.indices, id: \.self) { index in
    TrackRow(track: tracks[index])
}

// ❌ BAD: Array enumeration recreates identity on every change
ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
    TrackRow(track: track, rank: index + 1)
}

// ✅ GOOD: Use stable model identity
ForEach(tracks) { track in
    TrackRow(track: track)
}

// ✅ GOOD: If you need index for display (charts), use element ID
ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
    TrackRow(track: track, rank: index + 1)
}
```

## ❌ Background Tasks Not Cancelled on Deinit

```swift
// ❌ BAD: Task continues after ViewModel is deallocated
@Observable @MainActor
class HomeViewModel {
    private var backgroundTask: Task<Void, Never>?
    
    func startLoading() {
        backgroundTask = Task { /* ... */ }
    }
    // Missing deinit cleanup!
}

// ✅ GOOD: Cancel tasks in deinit
@Observable @MainActor
class HomeViewModel {
    private var backgroundTask: Task<Void, Never>?
    
    func startLoading() {
        backgroundTask?.cancel()
        backgroundTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            // ...
        }
    }
    
    deinit {
        backgroundTask?.cancel()
    }
}
```

## ❌ Shared Continuation Tokens Across Different Requests

```swift
// ❌ BAD: Single token for all search types causes conflicts
class YTMusicClient {
    private var searchContinuationToken: String?  // Shared!
    
    func searchSongs() { /* sets token */ }
    func searchAlbums() { /* overwrites token! */ }
}

// ✅ GOOD: Scope tokens by request type or return in response
class YTMusicClient {
    private var continuationTokens: [String: String] = [:]
    
    func searchSongs() -> (songs: [Song], continuation: String?) {
        // Return token with response, let caller manage
    }
}
```

## ❌ Treating Generated IDs as Navigable API IDs

```swift
// ❌ BAD: Hash/UUID IDs pass this check but aren't real channel IDs
if !artist.id.isEmpty, !artist.id.contains("-") {
    navigateToArtist(artist)  // 400 error from API!
}

// ✅ GOOD: Check for the actual YouTube channel ID prefix
if artist.hasNavigableId {  // Checks id.hasPrefix("UC")
    navigateToArtist(artist)
}
```

Home page items often have subtitle runs with no `navigationEndpoint`, causing
`ParsingHelpers.extractArtists()` to generate SHA256 hash IDs. These hex strings
have no hyphens and pass naive `!contains("-")` checks, but fail when used as
API parameters. Always use `hasNavigableId` which validates the `UC` prefix for
artists (or `MPRE`/`OLAK` for albums, `MPSPP` for podcasts).

## ❌ Mode Flags That Select a View Branch

An `if`/`else` on a presentation flag gives the branches different structural identities, so SwiftUI throws
away the whole subtree — `@State`, scroll positions, in-flight loads — every time the flag flips. Wrapping
the app's root content in `if showFullscreenNowPlaying { … .hidden() } else { … }` rebuilt every screen on
every fullscreen open/close, which is why the player bar's artwork fell back to its placeholder on both

transitions.

```swift
// ❌ BAD: toggling the flag destroys and recreates the entire content tree
if playerService.showFullscreenNowPlaying {
    Group { self.mainContent }.hidden().allowsHitTesting(false)
} else {
    Group { self.mainContent }.allowsHitTesting(true)
}

// ✅ GOOD: one identity, the flag only drives modifiers
self.mainContent
    .opacity(playerService.showFullscreenNowPlaying ? 0 : 1)
    .allowsHitTesting(!playerService.showFullscreenNowPlaying)
```

A conditional *overlay* is fine — overlays do not change the identity of the content underneath.

## ❌ Clearing Displayed Artwork When Its URL Changes

YouTube serves one picture from many URLs: `sqp` signatures rotate per response, size tokens differ
between the API listing and the player-bar `<img>`, and the WebView rewrites that `<img>` while it
upgrades resolution. Treating every URL change as a new image blanks the artwork the user is already
looking at — and because a `.task(id:)` only re-runs when its id changes, a failed replacement left
the placeholder on screen until the next track change.

```swift
// ❌ BAD: Any URL change (even the same art, re-signed) drops back to the placeholder
.onChange(of: url) { _, _ in
    image = nil
    isLoaded = false
}

// ❌ BAD: The player bar's <img> variant replaces the artwork the song is already showing
let intendedThumbnailURL = normalizedThumbnailURL(observedDOMThumbnail) ?? song.thumbnailURL
self.currentTrack = Song(/* ... */, thumbnailURL: intendedThumbnailURL, /* ... */)

// ✅ GOOD: Artwork views take a stable identity and keep the image for that identity
CachedAsyncImage(url: track.thumbnailURL, identity: track.videoId) { image in ... }

// ✅ GOOD: The song's own artwork wins; the observed thumbnail is only a fallback
let intendedThumbnailURL = song.thumbnailURL ?? normalizedThumbnailURL(observedDOMThumbnail)
```

Three rules follow from this: a URL change is not a content change, so only re-point `currentTrack`
(and friends) at a new artwork URL when the previous one is missing; only pass `identity` where the
artwork belongs to one entity for the view's whole lifetime — not in collection rows, which SwiftUI
may recycle for a different item; and **claim the identity before awaiting the download**, because an
update that re-reports the artwork while it is still downloading otherwise compares against the
previous identity and clears the image. That last one is a race: it only bites when the second update
lands before the download finishes, so the artwork vanished intermittently instead of always.

Artwork loads also need a retry. A view's `.task(id:)` runs only when its id changes, so one failed
fetch used to strand the placeholder until the next track change — nothing else would re-trigger it.

## Pre-Submit Checklists

### Performance

> See [architecture.md#performance-guidelines](architecture.md#performance-guidelines) for detailed patterns.

- [ ] No `await` calls inside loops or `ForEach`
- [ ] Long, scroll-critical lists of rich rows use `List`, not `ScrollView` + `LazyVStack`:
      a `LazyVStack` re-measures and re-renders the whole realised page every scroll frame, so
      scroll cost scales with each row's view-tree size — see
      [adr/0014](adr/0014-playlist-scroll-performance.md)
- [ ] Network calls cancelled on view disappear (`.task` handles this)
- [ ] Parsers have `measure {}` tests if processing large payloads
- [ ] Images use `ImageCache` with appropriate `targetSize`
- [ ] Search input is debounced
- [ ] ForEach uses stable identity
- [ ] Large lists use their own row view (not inline row builders in the parent body) so a
      parent update doesn't rebuild every visible row — see
      [adr/0014](adr/0014-playlist-scroll-performance.md)
- [ ] Rich rows in a `List` draw their highlight **full-bleed** at row level (zero
      `listRowInsets` + an internal content inset). Right-clicking a row makes SwiftUI decorate
      the whole row — full-width fill plus a 2 pt accent outline — and that decoration cannot be
      removed (`selectionHighlightStyle = .none`, `focusRingType = .none` on the table/row/cell
      views, `deselectAll` and `.focusEffectDisabled()` all leave it in place). A highlight that
      is inset and rounded disagrees with it, so the row's own highlight has to occupy the same
      rectangle (see [adr/0014](adr/0014-playlist-scroll-performance.md))

### Concurrency Safety

- [ ] No fire-and-forget `Task { }` without error handling
- [ ] Optimistic updates handle `CancellationError` explicitly
- [ ] Background tasks cancelled in `deinit`
- [ ] Using `.task` instead of `.onAppear { Task { } }`
- [ ] Continuation tokens scoped per-request (not shared across types)
- [ ] No `static var shared` pattern with mutable assignment in `init`
- [ ] WebView message handlers removed in `dismantleNSView`
- [ ] `WKNavigationDelegate` implements `webViewWebContentProcessDidTerminate`
