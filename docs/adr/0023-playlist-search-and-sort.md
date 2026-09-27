# ADR-0023: Whole-Playlist Search and Server-Synced Playlist Sorting

## Status

Accepted

## Context

`PlaylistDetailView` renders a playlist page by page: `getPlaylist(id:)` returns the header plus the
first page, and scrolling pulls continuation pages. Two long-standing gaps follow from that:

- **Search only saw the loaded page.** There is no in-playlist search endpoint in the innertube
  surface Kaset uses, so a naive filter would only match the first page or two — for a
  2,000-track playlist, most songs would be invisible to search.
- **No sort control.** YouTube Music lets an owner sort their own playlist and **stores the choice
  server-side**, so the same playlist opens in the same order on every device. Kaset had no way to
  read or change that order, and it silently showed whatever order the server returned.

Research (2026-09-27) established how sorting works:

- ytmusicapi's `edit_playlist(sortOrder:)` issues
  `browse/edit_playlist` with `actions: [{action: "ACTION_SET_PLAYLIST_VIDEO_ORDER",
  playlistVideoOrder: <int>}]`, where the values are `0` Manual, `1` Newest first, `2` Newest last
  ("Oldest first"), `6` Top voted.
- A Watch Later userscript reads the current selection from the page's sort menu, whose options each
  carry an `ACTION_SET_PLAYLIST_VIDEO_ORDER` action. The YT Music header exposes the same action,
  wrapped either in `sortFilterSubMenuRenderer` (classic submenu, `selected` flag on each item) or
  in `musicSortFilterButtonRenderer` (dropdown options, current selection in the button's title).

No auth cookies were available in this environment, so the owned-playlist header shape could not be
re-verified live.

## Decision

**Search loads the whole playlist, then filters locally.** Typing into the playlist's search field
calls `PlaylistDetailViewModel.loadAllTracksForSearch()`, which suspends the scroll-driven prefill
and walks every remaining continuation page once, coalescing repeated calls onto one scan.
`isLoadingAllTracks` drives a "Searching all songs…" status row, and paging is switched off while a
query is active. When the scan finishes, filtering is instant and local, matching title, artist, and
album.

**Sorting is treated as server state, not local state.** `PlaylistDetail` carries `sortOrder`,
`availableSortOrders`, and `isEditable`, and `PlaylistSortOrder` models the stored order values.
`PlaylistParser.parseSortState` scans the browse response for the `ACTION_SET_PLAYLIST_VIDEO_ORDER`
action rather than a fixed path, so it survives both menu shapes and degrades to "no sort menu" when
the response has none. `setPlaylistSortOrder(playlistId:sortOrder:)` writes the new order and the
view model reloads, so the on-screen order always matches what the account now stores.

**The UI mirrors YouTube Music.** A toolbar sort menu appears whenever the playlist is not an album
and a sort is offered — either the header's own menu or the standard set for **Liked Music**, whose
browse response does not carry the editable header a normal playlist has. The active order is shown
by a check mark on the selected option in the dropdown (the menu's `help` text names it too). A
compact, fixed-width search field sits in the toolbar, and picking a result plays the filtered list
rather than the full playlist.

**The header is the list's first row, and scrolls with the tracks.** It started that way. It was then
moved out into a `VStack` above the list to escape the table's row model, which introduced a worse
problem: a header outside the list is a flexible child of the page's stack, and the pages that
followed both overflowed the window and stopped scrolling (see below). It is back in the list.

**The header's height is definite, so the row cannot stretch.** The action row is aligned to the
thumbnail's bottom edge by a `ZStack(alignment: .bottomLeading)` instead of a `Spacer` above it, and
the row's height is therefore the thumbnail's 180 pt plus the row insets. This is what keeps the
buttons on the thumbnail's baseline in every layout the header has been through — as a row, as a
page's first child, and alongside a pinned header:

- A `Spacer` between the credits and the action row made the header flexible in height. As the list's
  first child that made the page's stack share the tracks list's leftover space with it, and the
  buttons drifted ~140 pt below the credits.
- Pinning the header with `.fixedSize(horizontal: false, vertical: true)` fixed the buttons but broke
the page: the list then answered the layout pass with the container's full height (732 pt of 734),
  the page measured 961 pt in a 734 pt window, and the stack centred the overflow — the header slid
  ~113 pt up until its top, and the toolbar controls over it, were clipped off the window.
  `.frame(maxHeight: .infinity)` on the list did not change it.

The `ZStack` version needs neither `Spacer` nor `fixedSize`, and it still grows if a title or the
credit list wraps.

**The credit pushes programmatically instead of using a `NavigationLink`.** Inside a `List` row a
value-based link makes the whole row selectable, which produced both defects the header-row layout is
remembered for, and both are reproducible with `PlaylistArtistNavigationUITests`:

- The table kept *its* selection painted over the whole header — accent red while the window was key,
  gray while it was not — and it stayed painted across a push and pop. `.listRowBackground(Color.clear)`
  does not reach that decoration (ADR-0014), `.selectionDisabled(true)` did not stop it, and nor did
  `.listRowSelectionDisabled` — that modifier does not exist on macOS, despite existing on iOS.
- Once the link had pushed the artist page it kept the activation, so a second click on the same
  credit was swallowed and the artist page stopped opening. `.borderless` on the link, rebuilding the
  row on return, and a one-second settle before the next click all failed.

The credit is now a plain `Button` that pushes through `NavigateToArtistAction` from the environment,
which `DetailNavigationStack` provides from the path it owns. With no link in the row there is no row
selection to paint and no activation to go stale; the artist page is still built by the same
`navigationDestination(for: Artist.self)` registration. (An earlier attempt at a programmatic push
added a *second* `navigationDestination` inside a view that is already a destination, which makes
SwiftUI loop and freeze — the destination registration must stay where it is.)

`testHeaderActionRowSitsOnTheThumbnail` asserts the geometry and the scrolling: the action row ends
with the thumbnail, the gap above it stays under 100 pt, the thumbnail stays inside the window, and
swiping the list carries the header with it. `PlaylistArtistNavigationUITests` clicks the credit,
presses Back and clicks it again, which is the click that used to be ignored.

## Consequences

### Positive

- Search covers the entire playlist, not just the loaded page, with honest progress feedback.
- The sort control reflects and mutates the same server-side order YouTube Music uses, so the
  ordering stays consistent across clients.
- The parser is shape-tolerant: it reads the order from wherever the action appears, so a header
  formatting change degrades to "no sort menu" instead of showing a wrong selection.

### Negative

- The header's height is the thumbnail's 180 pt plus the row insets, so it cannot be squeezed for a
  short window the way a flexible height could; the action row clips instead of shrinking below it.
  Scrolling does recover the space, since the header scrolls with the tracks.
- The credit is not a `NavigationLink`, so it has no link affordances (no ⌘-click, no hover cursor
  treatment). Pushing is a plain button action through the environment.
- A whole-playlist scan issues one continuation request per page; a very large playlist takes
  noticeable time on first search (once per view model, then cached in memory).
- The live YT Music header shape for sort could not be verified in this environment; if it differs,
  the sort menu simply does not appear until the parser is updated.

### Neutral

- Sorting is offered only where a write can succeed: a non-album playlist the signed-in user can
  edit, plus Liked Music, which is sortable although its header carries no editable marker. A menu the
  server advertises for a playlist we do not own used to be offered too, and the write answered
  `HTTP 400`.
- An unknown stored order is treated as Manual, the documented server default, when deciding which
  option to check.
- Order changes invalidate the mutation caches, so a following refresh fetches the reordered tracks
  instead of a cached page.
