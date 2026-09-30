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
Retries have to outlive that quick burst, too. The artwork losses that actually reach users last
longer than a couple of seconds and then fix themselves (the app is still opening its WebView and the
network is busy, a streamed song's picture is being upgraded, the CDN answers a rate-limited 403), so
the view keeps retrying — on a slower cadence, up to a minute — for as long as it stays on screen.
That is the difference between "the artwork appears late" and "the artwork never appears": the URL
itself does not change again, so nothing else would ever re-run the load. Log the failures with
`privacy: .public` for host and path only (never the query, which carries the signature) — an
interpolated `String` is private by default, and a wall of `<private>` is why a blank picture could not
be diagnosed from the log at all.

Metadata reconciliation has the mirror-image rule: **a picture that arrives while the track plays is
not a track change, so it needs its own reason to be reconciled.** A song that starts while the WebView
is still opening can be left without artwork — `fetchSongMetadata` can lose the race against account
initialization, and the player bar's `<img>` is empty until the page renders the track — and the
observer only reached the metadata reconcile on `trackChanged`. The picture the WebView had was
therefore dropped on the floor, and the now-playing art stayed blank for the whole song.

```swift
// ❌ BAD: the artwork the WebView reports later never reaches the playing track
let shouldReconcileMetadata = (trackChanged || self.playerService.repeatMode == .one)
    && (observedVideoId != nil || !title.isEmpty)

// ✅ GOOD: an equivalent observation of the *same* video is also reconciled when the track has no
// artwork yet, and the reconcile itself only takes the WebView's picture because we have none
let shouldReconcileMetadata = (trackChanged
    || self.playerService.repeatMode == .one
    || self.playerService.shouldReconcileMissingArtwork(observedVideoId: observedVideoId, …))
    && (observedVideoId != nil || !title.isEmpty)
```

Two more rules come out of the same "one picture, many URLs" property, and both show up as *the
artwork is not sharp* rather than as missing art. **Ask for the still by its largest name**:
`i.ytimg.com` serves `default.jpg` / `mqdefault.jpg` / `hqdefault.jpg` / `sddefault.jpg` (120x90 up to
640x480) and its 1280x720 stills exist only as `maxresdefault.jpg` / `hq720.jpg`, while the API answers
a large share of tracks with `sddefault.jpg`. Without promoting that name the preferred candidate *is*
the 640x480 still, so the largest artwork surface in the app (fullscreen, 380pt ⇒ 760px on Retina)
draws it upscaled. And **treat a cached decode as size-specific**: `ImageCache`'s memory cache holds one
image per URL, so whoever decodes a URL first fixes its resolution for every other view —
`isSufficientResolution` counts a decode made for a smaller slot as a miss and re-decodes from the
cached original bytes instead, which costs no extra request.

## ❌ Features That Depend on a View Being Rebuilt

Once a presentation stops tearing down the views behind it, everything that used to be re-initialized
by "a new view instance" has to be re-initialized explicitly — and everything that used to become
non-interactive by being destroyed now has to be made non-interactive on purpose. The fullscreen
now-playing overlay is the reference case: `MainWindow` keeps the content alive behind it, and the
overlay itself is driven by `showFullscreenNowPlaying` rather than by its own lifetime, so that it
behaves identically whether or not SwiftUI recreates it.

```swift
// ❌ BAD: only set up when the view happens to be created, teardown only in onDisappear
.onAppear { self.seekValue = self.normalizedProgress; self.installEscapeKeyMonitorIfNeeded() }
.onDisappear { self.removeEscapeKeyMonitor() }

// ✅ GOOD: the flag is the state machine; onAppear and onDisappear just forward into it
.onAppear { if self.playerService.showFullscreenNowPlaying { self.startPresentation() } }
.onChange(of: self.playerService.showFullscreenNowPlaying) { _, isPresented in
    isPresented ? self.startPresentation() : self.endPresentation()
}
.onDisappear { self.endPresentation() }   // idempotent, so both paths may run
```

The same reasoning applies to hidden content. `opacity(0)` hides a subtree but leaves it *live*, so
the obscured content must also be inert — `.disabled(isObscured)` resigns keyboard focus and blocks
keyboard activation, which otherwise lets a focused text field behind the overlay consume keystrokes
and lets the player bar's hidden Space/arrow shortcuts race the app's Playback menu commands.

Two smaller rules come out of the same transition: canvas and lyric loads key their `.task(id:)` on
`presentation + track`, not on the track alone, so reopening the overlay re-runs them; and shared
subsystems with one global flag need an explicit hand-off. The WebView's high-frequency lyric poll is
one flag consumed by two views, so the sidebar panel and the fullscreen lyrics pass it over instead of
stopping it (`LyricsPollHandoff`, covered by `LyricsPollHandoffTests`).

## ❌ Doing a Page's Navigation from Somewhere Other Than the Page

A view that is pushed onto a `NavigationStack` can be navigated *by value*, or by a path it is handed.
Two shapes look right and are not:

```swift
// ❌ BAD: an environment action for a pushed page, set on the stack that pushed it
NavigationStack(path: $path) { content }
    .environment(\.someAction, actionThatPushes)   // the pushed page reads the default, not this
```

```swift
// ❌ BAD: a destination on a page that is itself a destination — the app hangs
var body: some View {
    content.navigationDestination(item: self.$selection) { … }   // main thread never returns
}

// ✅ GOOD: a value-based link, the way the context menus' Go to Artist does it
NavigationLink(value: artist) { Text(artist.name) }

// ✅ GOOD: a control that cannot be a link — one in a List row, say — pushes through the path the page
// was handed when its destination was registered
Button { onNavigateToArtist(artist) } label: { Text(artist.name) }
```

The environment form is invisible until it is clicked: `navigateToArtist` was handed to every stack that
could show a playlist or album page, and in the running app the credit still read the default action on
every click — the unified log said so thirty times in one session. Hosted tests that push pages onto a
stack pass, which is why `ArtistCreditTests` guards the shape at the source instead. The page's root is
also not free to add its own `navigationDestination`: the page is a destination already, and a second
destination on the same stack does not push — it pins the main thread in `NSHostingView.layout` until
the window stops answering, which also does not reproduce without the real page's `List` and toolbar.

Values that reach pushed pages reliably are the ones injected far above them — `KasetApp`'s
`playerService`, `MainWindow`'s `libraryViewModel` — not ones set on the stack in between. A path handed
in as an initializer parameter is better still: it is not an environment lookup at all.
`navigationDestinations(client:artistPath:)` takes the path of the stack the destinations are registered
on, so a page that needs to push itself gets, from whoever pushed it, the path it is shown in. Every
stack that can show such a page has to pass its own — the eight top-level views, `LibraryView`, and the
`DetailNavigationStack` routes in `MainWindow`, which is why that stack now hands its path to its content
closure.

### …and one `List` row can carry only one link

A row's tap area is the whole row, so a second value-based link in the same row is not a second target:
**both links fire on one click and the stack lands on the last one.** A row is also what the list
decorates: a `NavigationLink` — and a `Menu`, whose items inherit the row's activation — makes the table
treat the row as the navigation source, so the row is selected (its highlight painted over the whole row
for as long as the page lives, accent while the window is key and gray while it is not) and keeps its
activation, which swallows the next click on the same control.

```swift
// ❌ BAD: one link per credited artist in the header row — clicking a name opens the *last* artist
List {
    HStack {
        ForEach(artists) { artist in
            NavigationLink(value: artist) { Text(artist.name) }
        }
    }
}
```

```swift
// ✅ GOOD: one button per artist, each pushing through the path the page was handed
HStack {
    ForEach(artists) { artist in
        Button { onNavigateToArtist(artist) } label: { Text(artist.name) }
            .buttonStyle(.plain)
    }
}
```

Links inside a `Menu` or a `contextMenu` are fine when the row they hang off is not itself the thing that
navigates — `PlaylistTrackRow` navigates from the menu of a row that plays when it is clicked. What is not
fine is a navigation the row starts. The multi-artist credit looked like a parsing bug because a
single-credit album worked: one link in the row is a row target, several are a lottery. See
[adr/0023](adr/0023-playlist-search-and-sort.md).

## ❌ `Task {}` Used to Leave the Main Actor

`Task {}` inherits the actor it is created in, so inside a `@MainActor` type it runs *on* the main
actor. `Task.detached` is the only form that actually steps off it. Code that claims to "perform I/O
off the main actor" while using `Task` is doing the opposite — the call is awaited, but it is still
main-actor work.

```swift
// ❌ BAD: this method is @MainActor, so Task {} inherits the main actor despite the comment
@MainActor func restoreCookies() async {
    let data = await Task(priority: .utility) { KeychainCookieStorage.loadArchiveData() }.value
}

// ✅ GOOD: detached really leaves the actor
@MainActor func restoreCookies() async {
    let data = await Task.detached(priority: .utility) { KeychainCookieStorage.loadArchiveData() }.value
}
```

The cost is not theoretical for blocking APIs. macOS answers a Keychain access prompt by blocking the
*calling thread* until the user responds, so a main-actor `SecItemCopyMatching` freezes the whole app —
no drawing, no input, and no scheduled Sparkle update check — until someone clicks. `WebKitManager`
restored its cookie archive that way, which is why an unattended `Scripts/test-update-flow.sh` run on a
machine whose Keychain prompt was unanswered looked exactly like a broken updater. A detached task also
requires the work to be `Sendable`; when it is not, move it into a `nonisolated` function instead.

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
- [ ] I/O that must not block the UI uses `Task.detached`, not `Task { }`, which inherits the actor —
      see [the pattern above](#-task--used-to-leave-the-main-actor)
- [ ] WebView message handlers removed in `dismantleNSView`
- [ ] `WKNavigationDelegate` implements `webViewWebContentProcessDidTerminate`

### Navigation

- [ ] A view that is itself a destination registers no `navigationDestination` of its own: a second
      destination on the same stack freezes the app, and a hosted test does not reproduce it — see
      [adr/0023](adr/0023-playlist-search-and-sort.md)
- [ ] A `List` row starts no navigation of its own: a `NavigationLink`, and a `Menu` whose items
      navigate, make the table select that row — its selection is painted over the row (accent while the
      window is key, gray otherwise) for as long as the page lives, and the row's activation is kept, so
      a second click on the same control is swallowed. A row's tap also reaches *every* link in it, so
      two links are one click that fires both. Navigate from a button that appends to the stack's path
      instead — see [adr/0023](adr/0023-playlist-search-and-sort.md)
- [ ] A page that pushes from a button is handed the stack's path
      (`navigationDestinations(client:artistPath:)`, `DetailNavigationStack { path in … }`); a stack that
      can show such a page must pass its own — see [adr/0023](adr/0023-playlist-search-and-sort.md)
- [ ] A header block that scrolls with the content is the list's **first row**, not a section header:
      on macOS a section header is a floating group row that sticks on top of the tracks for the whole
      scroll — see [adr/0023](adr/0023-playlist-search-and-sort.md)
