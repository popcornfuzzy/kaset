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
It is **off by default**, so the classic panels remain the default experience and nothing about them
changes for anyone who does not opt in.

### A column, not a panel

The sidebar is a real trailing column of `MainWindow`'s `HStack`, laid out *beside* the
`NavigationSplitView`, exactly like the navigation sidebar rather than as a floating card:

```swift
HStack(spacing: 0) {
    NavigationSplitView { Sidebar(…) } detail: { self.detailView(…) }
        .frame(minWidth: Layout.detailMinWidth)
        .overlay(alignment: .trailing) { NowPlayingSidebarResizeHandle(…) }
    if self.playerService.isNowPlayingSidebarVisible {
        NowPlayingSidebarView(columnWidth: self.effectiveColumnWidth)
            .frame(width: self.effectiveColumnWidth)
    }
}
// The stack's own width is the space available to the detail area.
.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { self.contentAreaWidth = $0 }
```

The system's `.inspector` was tried first and **rejected**: SwiftUI's inspector nests a second
`NSSplitViewController` inside the `NavigationSplitView`, and resizing that nested controller
invalidates constraints re-entrantly during the display cycle, which aborts the app
(`_postWindowNeedsUpdateConstraints`). A plain `HStack` child cannot perturb the split view's layout,
so this column is stable under every resize.

The column is resizable by dragging the edge next to it (`NowPlayingSidebarResizeHandle`, a small
`NSView` that owns the `resizeLeftRight` cursor) between 300 and 560pt; the width is persisted in
`SettingsManager.nowPlayingSidebarWidth` and clamped on read. Its collapse control
(`NowPlayingSidebarToggle`, the mirrored `sidebar.trailing` glyph) appears in exactly one place at a
time: in the window toolbar while the column is closed, and in the column's own top-trailing corner
while it is open — so it reads as sliding into the sidebar rather than being duplicated. The
transport's lyrics/queue buttons and ⌘L drive the same state, so the column, the toggle and the
shortcuts can never disagree.

**The toggle is deliberately never in the toolbar while the column is open.** The toolbar lays its
items out across the whole window and knows nothing about the column, so anything trailing lands on
top of it; worse, when two items share a placement macOS draws one stretched glass capsule behind the
run, which is what turned the toggle and the playlist search field into a single long pill. Keeping
the open column's toggle inside the column removes the overlapping run entirely, and leaves the
content's own search/sort/refresh buttons where they belong: in the toolbar, at the trailing edge.

**The column is always clamped to the space the window can give it.** A plain `HStack` resolves an
over-tight fit by letting the *fixed* child win and the flexible one overflow underneath it — which is
exactly the detail view being cropped behind the sidebar. So the column's drawn width is not the raw
setting: `NowPlayingSidebarColumnGeometry` caps it at `availableWidth - detailMinWidth - handle`, so
the stack always fits and nothing can be covered however far the divider is dragged. That arithmetic
lives in one testable value type rather than inline in the view
(`NowPlayingSidebarColumnGeometryTests`), because it is the invariant the whole layout rests on.

**The drag never mutates the window.** The divider writes its width to view state, persists it once
(on `mouseUp`), and only then re-derives the window minimum. An earlier version wrote
`SettingsManager` and re-derived the window minimum on every mouse-move event, so the window tried to
resize itself *between* the steps of a drag — together with the missing clamp, that is what made
resizing feel like it was fighting back and cropped the content.

**The sidebar takes its width as input.** `NowPlayingSidebarView(columnWidth:)` is told the width it
is drawn in and never measures its own width; a measured width lags the frame it measures by one
layout pass, which is what left the artwork and the embedded queue a step behind the column mid-drag.
Only the *height* is still measured, so the artwork can give up height on a short window.

The window's minimum stays at `detailMinWidth + handle + minWidth`; it deliberately does not grow with
the column's current width. A column wider than the window admits is shown clamped and returns to its
set width when the window is widened again, the way a resizable inspector behaves. Opening the column
still nudges the window wider if it is too narrow for the column's set width, deferred to the next
runloop tick so it never mutates the window mid-update.

Presentation stays a three-value page state on `PlayerService`
(`NowPlayingSidebarPage`: `overview` / `lyrics` / `queue`, `nil` = hidden), separate from the classic
`showLyrics`/`showQueue` flags, and the column's presence is *derived* from it in `MainWindow`
(`isNowPlayingSidebarVisible`). Opening either design closes the other and exits fullscreen; entering
fullscreen closes the sidebar.

### A surface made of the album

The column's chrome is deliberately the album art, not a panel:

- **The artwork is flush to the top of the column**, edge to edge, with no inset and no corner
  radius. The background wash additionally bleeds *up* behind the toolbar (top edge only — ignoring
  every edge once let it spill sideways into the content, which read as the column being padded on
  the left), so the sidebar's colour still reaches the window's top edge. That bleed is the column's
  one incursion into the toolbar band, which is exactly where the content's own toolbar controls
  (playlist search, sort, refresh) sit on top of the column's x-range — so the wash and the artwork
  are both marked `.allowsHitTesting(false)`. They are decoration, and a `Color` in a background is
  hit-testable by SwiftUI: without this the invisible layer silently swallowed every click and scroll
  aimed at those controls (the visual artifact was fixed long before the input block was).
  No interactive view may ever occupy the toolbar band inside the column.
- **The background is a blurred copy of the cover** (`NowPlayingSidebarBackground`), filling the whole
  column. A blur — rather than a palette extracted from the cover — keeps the image's structure, so
  the column reads as one surface made of the album instead of a picture on a flat tint. A gradient
  scrim over it keeps text legible on any cover.
- **The hero dissolves into that wash**: the real artwork (or its animated canvas, when one is
  available) is masked with a bottom fade, so there is no seam between the cover and its color.
- **The lyric window and the up-next row sit in translucent glass cards**
  (`NowPlayingSidebarCard`), so the blurred colors show through them.
- **The collapse button lives in the column itself**, at its top-trailing corner, floating over the
  artwork in glass rather than sitting in the window toolbar. Because the column starts below the
  toolbar, the button is never hidden behind it.

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
  provider/variant footer, and the classic queue (reorder, automix chips, undo/redo, clear) embedded
  through `QueueSidePanelView(showsHeader: false, usesMaterialBackground: false)` at the column's
  width, which also sizes the queue table's column to it.

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
  glance, and it behaves like every other sidebar in the app (resizable, toolbar toggle, no
  floating-card chrome).
- The lyric preview and the classic panel render the same view, so they cannot drift apart; the
  state views and the source footer are literally the same code.

**Harder / accepted trade-offs**

- Two sidebar designs means the settings surface, the transport buttons and the toolbar toggle all
  have to stay honest about which one is live.
- The column has to own its own resize affordance and minimum-width accounting, since it no longer
  gets them from a system container.
- The sidebar's three-line window is a *window* onto a sheet sized for a full panel, so it relies on
  `.scrollDisabled` + `ScrollViewProxy` (the sheet keeps centering programmatically) rather than on a
  purpose-built three-row renderer.
- The expanded lyric page does not carry the classic panel's AI "Explain lyrics" action; the classic
  panel still has it.
- The lyrics loader is still duplicated between `LyricsView` and the sidebar — the shared *views* are
  extracted, the loading state machine is not. Extracting that too is the natural next refactor.
- The column's rendering is covered by unit tests only at the state-machine level
  (`PlayerServiceTests`); the AppKit queue table inside it cannot be asserted from unit tests.
