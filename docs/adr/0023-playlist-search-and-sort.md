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
rather than the full playlist. A `ToolbarSpacer(.fixed)` sits between the search field and the
refresh button: toolbar items in the same group share one glass background on macOS 26, so a toolbar
down to just those two (a playlist that cannot be sorted) drew them as a single pill with the
refresh glyph on the search field's trailing edge. The spacer ends the group the search field and
the sort menu belong to, which gives the refresh button its own background with or without a sort
menu present.

**`Top voted` is not offered.** The header can advertise `playlistVideoOrder: 6` for it, and the
write is accepted, but the reloaded playlist comes back in its previous order: selecting it showed a
check mark and changed nothing, which reads as the sort being broken. `PlaylistSortOrder` has no case
for `6`, so `PlaylistParser.videoOrder(in:)` drops it wherever a header advertises it, and the menu
lists only the orders that work.

**The order change is verified against the reloaded header, not assumed.** YouTube Music answers
`STATUS_SUCCEEDED` even when it keeps a different order, and the list then comes back unchanged.
Because the tracks carry no marker for the order they are in, that is indistinguishable from a sort
that did nothing. `changeSortOrder` compares the requested order with the one the reloaded header
reports and, when they differ, says so next to the header controls instead of leaving the user to
guess whether the click registered.

**The header is the list's first row, and scrolls with the tracks** (2026-09-28). It was a row first,
then a page's first child above the list, then the tracks section's `header:`, and the row is where it
belongs: a header outside the list is a flexible child of the page's stack, and the pages that followed
both overflowed the window and stopped scrolling (see below), while a section header on macOS is a
*floating group row* — it parks itself on top of the tracks for the rest of the scroll, a stickier
header than the page ever wanted. The row model's cost is real, but it is a property of the *control*
and not of the header: the row model decorates the row that *starts* a navigation. Clicking a credit
used to select the header row, and the table's selection stayed painted over the whole header for the
rest of the page's life, accent while the window was key and gray while it was not, on single- and
multi-artist albums alike — with the credit as a link and again with it as a menu.
`.listRowBackground(Color.clear)`, `.selectionDisabled(true)`, `.listRowSelectionDisabled` (which does
not exist on macOS) and rebuilding the row on return all left the decoration in place — the same
conclusion ADR-0014 reached for the list's other row decoration. What removes it is not touching the row
but not navigating from it: the credit is a plain button that pushes the artist onto the stack's own
path (below), and the table does not treat a button as a navigation source.

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

**Every credit is a button that pushes onto the stack's own path** (2026-09-28). `NavigationLink(value:)`
is the usual way to push: it is what the song context menus use for **Go to Artist**, and it resolves
against the nearest enclosing `NavigationStack` with nothing installed for it. In the header row it cost
two things — the table's selection staying painted across the header, and the row's activation being kept
once its link had pushed the artist page, so a second click on the same credit was swallowed. Neither
`.borderless` on the link nor `.selectionDisabled` nor rebuilding the row removed either. The credit is
therefore a plain `Button` per artist — one control per name, so a two-artist album opens the artist whose
name was clicked — calling `PlaylistDetailView.onNavigateToArtist`. The page is handed that closure by
whoever registered the destinations: `navigationDestinations(client:artistPath:)` takes the enclosing
stack's path and passes `artistPath.wrappedValue.append` down, `LibraryView` does the same for its own
hand-rolled destination, `MainWindow`'s `DetailNavigationStack` hands its path to its content closure for
the sidebar-playlist and Liked Music routes, and the `#Preview` passes a no-op. A pushed page cannot reach
the stack's path itself, so this is the one thing that has to be handed in; everything else the page needs
comes from the environment.

**A `List` row hands a click to every link in it, so the credits are not links** (2026-09-28). The header
row's tap area covers the row, and with one link per credited artist *all* of them fired: on a
multi-artist album the stack opened the **last** artist whichever name was clicked, while a single-credit
album worked — which is what made the bug read like a parsing problem at first. A `Menu` of those same
links fixed the multi-artist case and kept the inline comma-separated look, but a menu still starts its
navigation from the row, so the painted header came back with it, and the names ended up one click away.
With one plain button per name there is nothing left for the row to activate: the click goes to the button
under the pointer, which pushes exactly its own artist. `AccessibilityID.PlaylistDetail.artistCredit(_:)`
is per artist, so `PlaylistArtistNavigationUITests` — which clicks a credit, presses Back and clicks it
again — addresses one name directly.

Two mechanisms were built and abandoned before settling there. Both are recorded here because the first
looks obviously right and the second is the shape every "let the page own its navigation" suggestion
arrives as.

**An environment action the stack provides does not reach the page** (abandoned 2026-09-28).
`navigateToArtist` was injected with `pushesArtists(onPath:)` on the `NavigationStack` — in the nine
top-level views, in the detail column's own stack, and in `DetailNavigationStack` — and the credit was a
plain `Button` calling it. In the running app the credit read the *default* action on every click; the
unified log recorded about thirty `Artist credit … was clicked with no navigation stack providing an
action` lines from one session, so an album opened from a list did nothing while the page the stack was
created with (Liked Music) worked. Hosted tests that push pages onto a stack — including pages whose
credit sits in a `List` row — pass, so no test in this project catches it. The default action logging
instead of doing nothing was what made the failure visible at all.

**A page must not register a destination of its own** (abandoned 2026-09-28). `PlaylistDetailView` is
already a destination of the stack that shows it, and a second destination on that same stack — `for:`
*or* `item:` — does not push: the app stops answering and the main thread never returns. The `item:`
form (with the artist in the page's `@State`) was tried as the natural fix and hung the app on the
first click, with the main thread pinned in `NSHostingView.layout` under `PlaylistDetailView.body` and
an `OutlineListCoordinator` update, re-entering layout for as long as it was sampled. A hosted test that
pushes text pages does not reproduce it; the real page, with its `List` and toolbar, does.
`ArtistCreditTests` fails if `PlaylistDetailView` ever contains a `navigationDestination` again.

`ArtistCreditTests` guards the three rules this control has cost the most time to learn: the credit
pushes through the page's `onNavigateToArtist` closure and never through a `NavigationLink` or a `Menu`
in the header row, the page registers no destination of its own, and the header is the list's first row
rather than a section header.

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
- Every stack that can show the page has to hand it the artist path: `navigationDestinations(client:artistPath:)`
  takes the stack's `NavigationPath`, `LibraryView` passes its own to its hand-rolled destination, and
  `MainWindow`'s `DetailNavigationStack` routes use the binding it gives their content. A stack that
  forgets it does not compile, because the parameter is required.
- A credit is a button, so it has no link cursor, and Return does not open it the way a `NavigationLink`
  would.
- A whole-playlist scan issues one continuation request per page; a very large playlist takes
  noticeable time on first search (once per view model, then cached in memory).
- The live YT Music header shape for sort could not be verified in this environment; if it differs,
  the sort menu simply does not appear until the parser is updated.
- The verification can only speak when the reloaded header reports a selected order. A response that
  omits the selection (or a write whose effect the server applies only to later fetches) leaves it
  silent, and the order on screen is then whatever the server returned.

### Neutral

- Sorting is offered only where a write can succeed: a non-album playlist the signed-in user can
  edit, plus Liked Music, which is sortable although its header carries no editable marker. A menu the
  server advertises for a playlist we do not own used to be offered too, and the write answered
  `HTTP 400`.
- An unknown stored order is treated as Manual, the documented server default, when deciding which
  option to check.
- Order changes invalidate the mutation caches, so a following refresh fetches the reordered tracks
  instead of a cached page.
