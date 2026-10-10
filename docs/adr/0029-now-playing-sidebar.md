# ADR-0029: Now Playing Sidebar (Artwork-First Right Sidebar)

## Status

Accepted

## Context

The right side of the window has two designs that never coexist:

- the **classic panels** — `LyricsView` (a glass card, 280pt) and `QueueSidePanelView` / `QueueView`
  (a glass card or a popup, 400pt), both floating *over* the content in `MainWindow`;
- the **fullscreen player** — `FullscreenNowPlayingView`, which already renders cover art with the
  track's animated canvas, the karaoke lyric sheet, and the transport row.

The classic lyrics panel is a list and the classic queue panel is a table. Neither shows what is
playing, and the animated canvas — resolved by `CanvasService` and drawn by `CanvasVideoView` —
exists nowhere outside fullscreen.

A hybrid of the Spotify and Apple Music treatments was requested: the artwork carries the panel, the
lyrics only need to show where the song is, and the queue only needs to show what comes next, with
both of those opening into the full experience on demand.

Three constraints shaped the design:

- **the existing panels must keep working**, so the new design had to be a *choice*, not a
  replacement;
- the panel had to be a **real sidebar** — a column of the window with the standard toolbar collapse
  button, laid out by the window like the navigation sidebar — not another floating card;
- **the lyrics must not be re-implemented**: the three-line preview was asked for with "the same
  everything as the lyrics panel and fullscreen view".

## Decision

Add a third right-sidebar design, the **Now Playing sidebar** (`NowPlayingSidebarView`), selected by
`SettingsManager.nowPlayingSidebarEnabled`, surfaced as *Use Now Playing Sidebar* in General settings.
It is **on by default**: the column is the app's right sidebar out of the box, and the classic
lyrics/queue panels are what a reader opts into.

This started the other way round — the sidebar shipped **off**, so the existing panels could not
change under anyone — and was flipped once the column had replaced the panels' own jobs (the queue
is embedded in it, the lyric window is the same sheet) and its launch path was proven
(`PlayerService.init` opens the column when the setting is on, so the window's first layout already
has it). Worth stating because of how the default is *read*: `object(forKey:) as? Bool ?? true`
means the sidebar is the behaviour for a reader who has **never touched the setting** (no stored
key), while one who deliberately turned it off has a stored `false` and keeps the panels. The flip
therefore reaches new and untouched profiles, not people who stated a preference — and the classic
panels, their presentation state and the transport's lyrics/queue buttons all stay exactly as they
were for them.

### A column, not a panel

The sidebar is the window's third pane: `MainWindow` hands it to `WindowShell`, an
`NSSplitViewController` whose items are the navigation sidebar, the page and this column. AppKit owns
its divider, its collapse, its width bounds and its persistence, so the app owns only what is its
decision — whether the column is open, and the width it opens at the first time. The whole mechanism,
and why the window had to become AppKit's for it, is [ADR-0030](0030-appkit-window-shell.md).

It is the platform's *inspector* item (`NSSplitViewItem(inspectorWithViewController:)`), which is what
makes the window toolbar's standard inspector tracking separator line up with its divider — the
mechanism that keeps the page's own toolbar controls clear of the column.

The column is resizable by dragging its divider (AppKit's, with AppKit's cursor and clamping) between
300 and 560pt. Its collapse control is the window toolbar's **last item, open or closed**: while the
column is closed it is the trailing control of the right-aligned run, and while the column is open it
is the trailing control of the toolbar's *inspector* region — the region above the column — pushed
there by a flexible space. It is the mirrored `sidebar.right` glyph with AppKit's own toolbar chrome,
aligned with every other control in the titlebar.

This is a correction. The toggle first appeared in exactly one place at a time — the toolbar while the
column was closed, and the column's own top-trailing corner while it was open — so that opening the
sidebar read as the toggle sliding into it. In the running app that in-column control sat *on the cover
art*, in the band the artwork is supposed to own: small, low-contrast, on top of whatever the album
looks like, and in the way of the artwork running to the window's top edge. The toolbar item,
meanwhile, is AppKit's own control for exactly this job. So the control stays in the toolbar, in the
region above the column, and **no interactive view occupies the column's backdrop band** — the rule the
artwork bullet below already stated. The transport's lyrics/queue buttons and ⌘L drive the same state,
so the column, the toggle and the shortcuts can never disagree.

The app's collapse state and AppKit's pane follow each other in both directions: a page change
re-derives the pane's collapse, and a collapse the reader performs — the toolbar toggle, a drag, a
double-click on the divider — is observed on the item and fed back through
`onInspectorCollapsedChange`, with the app's own writes flagged so they are not read back as a
reader's action.

**The width the reader drags is AppKit's to remember**, under `NSSplitView.autosaveName`.
`SettingsManager.nowPlayingSidebarWidth` is now only the width the column *opens at the first time*,
put through `NowPlayingSidebarColumnGeometry`'s bounds before it reaches the split view
(`NowPlayingSidebarColumnGeometryTests`); after that the divider is the source of truth and the app
never writes a width. That is what removes the whole class of "the stored width fights the divider"
bugs — the ones that made a drag feel like it was fighting back and cropped the content — at the
source, rather than by clamping harder.

**The sidebar takes its size as input, resolved in the pass that draws it.**
`NowPlayingSidebarView(columnWidth:columnHeight:)` never measures itself; the pane hands it the size
(`ShellPane`), and `ShellPane` reads that size from a `GeometryReader` — a layout container, so the
content is built with the size being resolved, in the same pass as the frame the divider is moving.
This is the second attempt at the same bug and the reason the first one failed: the pane used to
measure with `.onGeometryChange` into `@State`, which delivers the size on the *next* layout pass, so
every frame of a drag still drew stale content — the artwork and the embedded queue trailed the
divider, and if the artwork's height fed back into the next measurement the drag could visibly step.
The size is taken once, at the top, and nothing inside the column measures the column again.

**The embedded queue fills its width instead of being told one.** `QueueSidePanelView(width:)` takes
`nil` there, and the AppKit table sizes its column from the scroll view's own width in
`viewDidLayout`. A scalar width passed down from SwiftUI state is a *copy* of the column's width made
one pass earlier — the rows and their trailing controls would shift after the column edge did — while
the scroll view's width is current the moment AppKit lays it out. The classic floating panel still
states its fixed width, so nothing about it changes.

**The column holds its width when the *window* is resized.** The inspector item is given a holding
priority just above the page's (251 against the page's 249), so a window resize gives its space to the
page and leaves the reader's divider where they put it instead of the two flexible panes trading width
arbitrarily.

**Nothing about the column moves the window.** The window's minimum width used to be raised to the three
panes' minimums while the column was open — 200 + 680 + 300 = 1180 against a 900pt window. That is a
minimum the window cannot satisfy *at its own size*, so opening the column on a narrower window (and any
resize or divider drag on one) worked against an unsatisfiable requirement, which is what the window
jumping and the column collapsing on a drag were. The page is the pane that gives way instead: its
minimum follows the width the split view actually has, down to `WindowShellLayout.squeezedContentWidth`
(320pt), which is the same arithmetic the SwiftUI version of this column used to do in
`NowPlayingSidebarColumnGeometry.ceiling`. The window's own minimum stays the number its owner stated,
and the requirement is satisfiable at every width.

### The column's pages have no header of their own

The lyrics and queue pages first drew the "back to Now Playing" chevron and the page's name
*themselves*, just below the window's toolbar. That band is the window's chrome — content cannot be
laid out in it — so the whole band above a page was empty column, and only the overview filled it
(with the artwork, which is decoration and may sit under the toolbar). The header is the toolbar's
now: `WindowToolbarItem.sidebarHeader` sits at the leading edge of the region above the column and is
drawn by `NowPlayingSidebarToolbarHeaderView` (back chevron plus the page's name, the same shape the
in-column header had). It is the rule the collapse toggle already followed — the column's controls live
in the band above it — applied to the pages, and it is stated as an *item* rather than as text drawn on
the backdrop so the control stays clickable: what the toolbar draws, AppKit hit-tests.

`NowPlayingSidebarPage.toolbarTitle` is what the header shows (`nil` for `overview`, which *is* the top
of the column and has nothing above it to go back to), so the column's page state and its toolbar are
one statement. The pages therefore begin at the top of the column: the queue's rows run from the band's
bottom edge down to the footer, and the lyric sheet from the same line. The window title's own slot is
untouched — it is given up to the *page's* back control while the page can pop, and the column's header
is a separate item in the column's own region.

### The page's own controls are toolbar items, bounded by the column

When the column was laid out by SwiftUI, the playlist's search/sort/refresh (and the Library/History
refresh) could not be toolbar items at all: a `.automatic` `ToolbarItem` is pinned to the **window's**
trailing edge — over the column — and there is no placement that means "the trailing edge of the
content". Reserving the column's width with a transparent item moved them but made macOS 26 draw the
reservation as an empty glass capsule the width of the sidebar.

With the window shell in place ([ADR-0030](0030-appkit-window-shell.md)) both workarounds are gone and
the controls are back in the titlebar, where a macOS app puts them:

- A page **publishes** what it wants there and retracts it on disappearing (`PageToolbarModel`, keyed by
the page's id so the incoming page's publication cannot be cleared by the outgoing page's retraction).
- The window renders it as one hosted item (`PageToolbarContribution`), placed *before* the inspector
tracking separator — so the region it is laid out in ends at the column's divider and the controls can
never be drawn over the column, at any window size and any column width. Measured in the running app:
with the column's pane starting at x=1028, the playlist's search → sort → refresh group ends at x=1020.
- The controls read the **page's own model** during a render of the toolbar's tree, which is what keeps a
query typed in the titlebar and the list it filters in step. That is why the search text and the refresh
flag are model state (`PlaylistDetailViewModel.searchText`, `…isRefreshing`) rather than the page's
`@State`: one piece of state, two view trees. The refresh flag exists because a manual refresh is a
*background* refresh — `loadingState` stays `.loaded` throughout, so it cannot say whether one is
running.
- The Ask AI button and the page's controls are **separated by a fixed space**
  (`NSToolbarItem.Identifier.space`). macOS 26 fills one glass capsule behind a contiguous run of
  toolbar items, so two bordered controls next to each other are drawn as a single stretched pill; the
  space is a real item in the run, so each control keeps its own shape (`WindowToolbarLayoutTests`).

What is **not** done: nothing. The page row (`PageTrailingControls`) is deleted, and the last trace of
the old shape — `.toolbarBackgroundVisibility(.hidden, for: .automatic)` on a few pages that never had
these controls — is gone too: it was a no-op with the app stating the toolbar's item list, and it was
one of the SwiftUI requests that made SwiftUI's window controller manage the window's toolbar itself
(see [ADR-0030](0030-appkit-window-shell.md)).

Presentation stays a three-value page state on `PlayerService`
(`NowPlayingSidebarPage`: `overview` / `lyrics` / `queue`, `nil` = hidden), separate from the classic
`showLyrics`/`showQueue` flags, and the column's presence is *derived* from it in `MainWindow`
(`isNowPlayingSidebarVisible`). Opening either design closes the other and exits fullscreen; entering
fullscreen **leaves the sidebar where it is** — the player covers the window, so the column behind it is
out of sight either way, and closing it there changed the reader's window layout from a view they did not
touch (AppKit collapsing the split item, the window's minimum width restated for the panes that are left)
in the same turn the player was being put up. A column the reader had open is still open when they come
back out.

The **lyrics poll hand-off** follows from that: leaving the player hands the WebView poll over whenever a
lyrics sheet is still on screen, and the sheet that remains is usually this column. So the hand-off asks
the column's own page, not just the classic panel's `showLyrics` flag (`LyricsPollHandoff.isLyricsSheetVisible`),
and it reconciles the poll rather than only stopping it. The poll is what reports playback time
(`PlayerService.currentTimeMs`), so stopping it with lyrics still on screen froze this sidebar's karaoke on
the line it had reached — a stop that was correct only while opening the player closed the column.

### A surface made of the album

The column's chrome is deliberately the album art, not a panel:

- **The artwork is flush to the top of the column**, edge to edge, with no inset and no corner
  radius, and — because the column's pane reaches the window's top — it is genuinely behind the
  toolbar rather than below it. The background wash bleeds the same way (top edge only — ignoring
  every edge once let it spill sideways into the content, which read as the column being padded on
  the left), so the sidebar's colour reaches the window's top edge. The wash and the artwork are both
  marked `.allowsHitTesting(false)`: they are decoration, and a `Color` in a background is
  hit-testable by SwiftUI, so without this an invisible layer swallowed every click and scroll aimed
  at whatever was beneath it (the visual artifact was fixed long before the input block was).
  **No interactive view may occupy the backdrop band inside the column.**

  The artwork itself is pulled up over the toolbar band by the inset the column measures
  (`NowPlayingSidebarView.topInset`, the difference between the pane's top edge and its content's):
  reaching the top edge is a *property of the artwork*, not of the page, so only the artwork ignores
  the inset. The expanded pages start at the top of the column's content instead — their back control
  and name are toolbar items in the band above the column, never inside it (see *The column's pages
  have no header of their own*).
- **The background is a blurred copy of the cover** (`NowPlayingSidebarBackground`), filling the whole
  column. A blur — rather than a palette extracted from the cover — keeps the image's structure, so
  the column reads as one surface made of the album instead of a picture on a flat tint. A gradient
  scrim over it keeps text legible on any cover.
- **The hero dissolves into that wash**: the real artwork (or its animated canvas, when one is
  available) is masked with a bottom fade, so there is no seam between the cover and its color.
- **The lyric window and the up-next row sit in translucent glass cards**
  (`NowPlayingSidebarCard`), so the blurred colors show through them.
- **The collapse button is the toolbar's**, in the inspector region above the column, never inside the
  column: nothing interactive sits on the backdrop, so the artwork can run behind the toolbar without a
  control being drawn on it or hidden by it.

### The overview is the column

- **Artwork, edge to edge.** The cover spans the full column width, flush with the top, with the
  track's animated canvas crossfading over it. No card, no inset, no corner radius.
- **Title and artist under the artwork**, directly on the sidebar's own background — not in a
  caption card.
- **A three-line lyric window.** A section label with an expand chevron, then the *same*
  `SyncedLyricsDisplayView` the classic panel and the fullscreen player render, in a window
  116pt tall, faded at both edges. The sheet's own centering keeps the line being sung in the
  middle and the karaoke wipe, emphasis and pause dots are the panel's. It is windowed, not
  re-implemented: the only differences are `allowsScrolling: false` (a stray scroll in a window this
  short would push the highlight out of it and pause auto-follow for four seconds) and its rows
  opening the full page rather than seeking.
- **The next song** below it, also plain content on the sidebar background.
- Each section's label and its content expand into the full page — the shared lyric sheet with the
  provider/variant footer that carries the page's **refresh control**, and the classic queue (reorder,
  automix chips, undo/redo/clear, and the row context menu) embedded through
  `QueueSidePanelView(showsHeader: false, usesMaterialBackground: false)` at the column's width, which
  also sizes the queue table's column to it.
- The lyric page's refresh control sits at the **trailing edge of the sheet's source footer**
  (`LyricsSourceFooter`'s `onRefresh`), not beside the header: the header is the toolbar band's, where a
  refresh read as part of the back control's capsule, and refreshing means "search again for this song" —
  which is what the line under the sheet, the one that names the provider, already says. It is drawn in
  every lyric state, including "no lyrics", because a search that failed is the one worth re-running;
  the classic panel keeps its own refresh in its own header. The queue's controls stay inside the queue,
  in the footer below its rows.
- The queue's **footer is adaptive**: four actions whose names are shown while the row of them fits and
  whose glyphs (with tooltips and VoiceOver labels) are shown when it does not. The names need 289pt of
  panel and the column's floor is 300pt, so the column shows the names at every width it can have and the
  glyph version is what a *squeezed* row falls back to — neither version can produce the wrapped "Undo"
  over two lines the titled row used to break into (`QueueFooterLayoutTests` measures both).
- The queue is the **one page the column does not inset**: its rows are their own bands (the playing row's
  tint, and the row's hover), so a page inset put a grey gutter beside a coloured band instead of
  breathing room. The rows carry the insets instead, in the cell (`queuePage`).
- The queue's **playing row is locked**: a drop that would shift it shows no gap and is refused, and the
  model refuses the move as well (`PlayerService.reorderMovesPlayingRow`) — the row's index is what the
  highlight, the list's auto-scroll and the WebView's own alignment all read, so a reorder that changed it
  made the whole queue jump (`QueueReorderLockTests`). The lock is stated at the **drop**, not at the drag:
  a row the table refuses as a drag source is a row it hides on the press and never shows again (the
  unhide belongs to the drag session, and a session that never began never ends), so every row offers a
  drag and a release puts back any row a press left hidden
  (`DraggableTableView.restoreRowsAfterFailedDrag`, `QueueRowDragStrandTests`).
- The queue's rows draw their greys — the artist, the track number, the duration and the waveform at rest —
  in **literal colours picked by appearance**, not in `secondaryLabelColor`/`tertiaryLabelColor`: the
  sidebar's vibrant appearance re-resolves those to lower-alpha ones (black @ 0.50 and @ 0.30 under
  `VibrantLight`), which over the material left the row's secondary text at near-background greys. It is
  the same escape `Sidebar.rowForeground(for:)` takes, and the waveform's bars are layers, so they are
  re-resolved when the appearance changes (`QueueRowTextColor`, `QueueRowTextColorTests`).
- The queue's rows carry their **right-click menu** (`DraggableTableView.menu(for:)`), which is the only
  place AppKit asks a table for a row's menu. It was built in a method named `menuForRow` that AppKit
  never calls — there is no such delegate hook — so the menu was dead code in the classic panel too, and
  the sidebar inherited the same silence.

### The album's own colors

The column's background (`NowPlayingSidebarBackground`) is a **blurred copy of the current cover**
laid over a `Color`: the blur keeps the image's structure — light where it is light, warm where it is
warm — so the column reads as one continuous surface made of the album rather than a picture on a flat
tint. A gradient scrim sits over it so text stays legible on any cover. The blur source comes from the
artwork the app *already has* — `ImageCache.shared.image(for:targetSize:)` is asked at a small size,
which the hero's decode already satisfies, so it costs no request — and is keyed to the track id, so a
re-reported URL for the same cover does not re-decode.

### One lyrics surface, shared

Behaving like the classic panel meant removing the divergence, not copying it. The pieces both
surfaces state were extracted into `LyricsSurfaceViews` and are now used by `LyricsView` as well:

- `LyricsStateView` — loading (with the provider being searched), no track, no lyrics. The sidebar
  passes `compact: true` for type size only; the wording, icons and messages are the same strings.
- `LyricsSourceFooter` — provider credit plus the community-variant picker.
- `LyricsSearchingCaption` — the "still searching for lyrics" shimmer.

The lyrics *lookup* pipeline (metadata-gated search, signature retry, poll handoff) is stated in two
places — `LyricsView` and the sidebar — and is character-for-character the same in both; the sidebar
keeps one copy on its root so its preview and its expanded sheet share it and a page change never
looks like a new track.

## Consequences

**Easier**

- The canvas, a fullscreen-only feature, is visible while browsing.
- The right sidebar answers "what is playing", "where am I in the lyrics" and "what is next" at a
  glance, and it behaves like every other sidebar in the app (draggable divider, remembered width,
  standard toolbar toggle, no floating-card chrome) without the app implementing any of that.
- The lyric preview and the classic panel render the same view, so they cannot drift apart; the
  state views and the source footer are literally the same code.

**Harder / accepted trade-offs**

- Two sidebar designs means the settings surface, the transport buttons and the toolbar toggle all
  have to stay honest about which one is live.
- The window's structure is AppKit's (see [ADR-0030](0030-appkit-window-shell.md)): the column's
  width, its divider and its collapse are no longer the app's to state, and the shell cannot be
  covered by unit tests, so its behaviour is verified by running the app and reading its view tree.
- The sidebar's three-line window is a *window* onto a sheet sized for a full panel, so it relies on
  `.scrollDisabled` + `ScrollViewProxy` (the sheet keeps centering programmatically) rather than on a
  purpose-built three-row renderer.
- The expanded lyric page does not carry the classic panel's AI "Explain lyrics" action; the classic
  panel still has it.
- The lyrics loader is still duplicated between `LyricsView` and the sidebar — the shared *views* are
  extracted, the loading state machine is not. Extracting that too is the natural next refactor.
- The column is covered by unit tests at the state-machine level (`PlayerServiceTests`), at the
  toolbar-item level (`WindowToolbarTests`, including the hosted header's own size), and at the layout
  level by hosting its views offscreen — the queue and lyric footers are rendered and their ink measured
  (`QueueFooterLayoutTests`), the queue table's menu is driven with a synthetic right click
  (`QueueSidePanelMenuTests`), the reorder rule is tabulated (`QueueReorderLockTests`), and the stranded
  row a refused drag leaves behind is repaired and its repair is read off the table
  (`QueueRowDragStrandTests`). What the
  column *draws* as a whole still has to be seen by running the app.
