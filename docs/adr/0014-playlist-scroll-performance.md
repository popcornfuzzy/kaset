# ADR-0014: Playlist Scroll Performance

## Status

Accepted

## Context

Scrolling a long playlist or album in `PlaylistDetailView` dropped frames. The list is a
`ScrollView` + `LazyVStack` (the convention across the app — `Sidebar` is the only `List`),
so only visible rows are realized; the cost was therefore *per realized row*, not
over-realization. Profiling review of the row implementation found five compounding costs:

1. **Rows were built inside the parent's body.** `trackRow` and `tracksView` were private
   functions of `PlaylistDetailView`, so every row was reconstructed as part of the parent's
   body evaluation. That body read `playerService.currentTrack`, `playerService.isPlaying`,
   and — while building each row's ~15-item context menu — `favoritesManager.isPinned`, which
   subscribed the whole list to `FavoritesManager`. A track change, a favorite toggle, or a
   page append therefore re-evaluated every realized row, twice over (context menu + ellipsis
   menu).
2. **Thumbnails decoded at the wrong size.** Rows passed no `targetSize` to
   `CachedAsyncImage`, so `ImageCache` downsampled 320×320 bitmaps for a 40×40 slot. The
   `ImageCache` actor serializes every cache miss, so wasted decode time is paid directly on
   the scroll path.
3. **Per-row entrance animations ran during scrolling.** `.staggeredAppearance(index:)` ran a
   `withAnimation` opacity/offset transition on each row's first appearance, including rows
   appearing mid-flick. The modifier's cache key was also index-based rather than item-based,
   so it suppressed animations for the wrong rows.
4. **Hover churn.** `InteractiveRowStyle` tracks hover per row; with the pointer resting over
   the list, every row passing beneath it swapped its background and started an animation.
5. **Paging sat on the scroll path.** `loadMore()` was triggered from an `.onAppear` on every
   row's `onAppear`, rebuilt a `Set` of every loaded video ID per page, and copied the whole
   track array on the main actor. `HomeViewModel`/`HistoryViewModel` already preload
   continuations in the background; `PlaylistDetailViewModel` did not.

Fixing those five did not remove the lag, so a second round measured where the frames actually
went: Time Profiler samples of a fast fling versus a normal scroll, then an in-app A/B. The
samples attributed ~48% of a fling (and ~34% of normal scrolling) to a window-level AppKit
layout pass that drives `NSHostingView.layout()` and re-runs the page's view-graph render, with
`LazyStack.place` a further ~15% and attributable app code at ~1%. That last figure was the
telling one: the cost of a row's view tree is real, but it is spent in framework code (layout
measurement, AttributeGraph, CoreAnimation commit) rather than in the row's `body`, which is why
row-level work alone could not move it.

The A/B identified the mechanism. Swapping the track rows for a minimal stand-in with the same
height — identical scroll geometry, ~7 view nodes instead of ~50 — took the main-thread tail
from p95 49.2 ms to 4.7 ms and passes over 8 ms from 43/240 to 5/240. Per-frame cost therefore
scales with the number of view nodes in the scrolling content, because a `LazyVStack`
re-measures and re-renders the whole realised page on every scroll frame. The same profile put
~12–15% of main-thread samples in per-row hover tracking (`_NSTrackingAreaAKManager` cursor
updates, `EventBindingManager.enqueueHoverUpdateIfNeeded`,
`HoverResponder.containsGlobalPoints`), all of it scaling with the number of hover-tracked rows.
Placing the rich rows in a `List` instead was measured against the same playlist and made
scrolling smooth, which is what this ADR now specifies.

## Decision

### Track lists are rendered by an AppKit-backed `List`

`PlaylistDetailView` renders its header, divider and tracks inside a `List`
(`.listStyle(.plain)`, hidden row separators, clear row backgrounds, zero `listRowInsets` with the
row applying the page's 24 pt inset to its own content) instead of a `ScrollView` +
`LazyVStack`. NSTableView lays out and reuses row views and scrolls by moving the clip view, so
the per-frame cost stops scaling with the realised rows' view-tree size while the row design
survives intact: the row still draws its own separator, keeps its context menu, ellipsis menu and
add-to-playlist popover.

One `List` behaviour has to be worked around rather than undone. Right-clicking a row makes the
list decorate the row it targets: the row gets a full-width highlight and a 2 pt accent-coloured
outline (measured at `#D94359` against the app accent `#FF0056` — the muted tint an accent
indicator takes while the window is not key, which a window is while one of its menus is open).
That decoration is drawn by SwiftUI's list internals, not reachable as AppKit decoration, and
three attempts to remove it through AppKit changed nothing: `selectionHighlightStyle = .none` on the
backing `NSTableView` (`SwiftUIOutlineListView` in the hierarchy), `focusRingType = .none` on the
table and on every `ListTableRowView`/`ListTableCellView`, and `deselectAll` from the two
`NSTableView` selection notifications — with a temporary HUD confirming the table *was* found
(`1` table) while the outline stayed on screen. `.focusEffectDisabled()` was equally ineffective,
because it only covers SwiftUI's own focus effect. There is no public API that removes it, so the
decoration is now made to agree with the row instead of being fought.

That works because the row *is* the element the decoration is drawn around. `.listRowInsets(EdgeInsets())`
at the call site makes the row span the full width of the list, `PlaylistTrackRow.contentInset`
keeps the content at the page's 24 pt inset, and the row draws its hover/press highlight itself as a
full-bleed rectangle rather than letting `InteractiveRowStyle` paint an inset rounded pill around
the play button alone. The framework's highlight, the outline and the row's own highlight are then
the same rectangle, and the outline lands on the row's edge instead of cutting across the middle of
it. The style is invoked with `drawsBackground: false` so it contributes press feedback only. This is
the one place worth knowing about when editing the row's appearance: the highlight must stay
full-bleed, so any new row decoration belongs at row level, not inside the play button's label.

The alternatives were to keep the `LazyVStack` and diet the row's view tree, which is bounded at
roughly a 2–3× reduction and cannot reach the measured slim-row behaviour, or to accept the
jank. `List` was chosen because it decouples scroll cost from row complexity rather than
trading design for frames.

### Rows are isolated, equatable views

`PlaylistTrackRow` is a dedicated view that receives only value data (`song`, `index`,
`isAlbum`, `isCurrentTrack`, `isPlaying`, `showsSeparator`, `isScrolling`) plus references and
action closures, and is applied with `.equatable()` in the list. Its `nonisolated` `==`
compares exactly the fields the row draws, so a parent-level update (track change, favorite
toggle, page append) skips the body of every unchanged row instead of rebuilding thousands of
view nodes.

Equality deliberately excludes the closures and service references. That is only sound because
the row never captures a track snapshot: `onPlay` calls back into the view model and reads
`playlistDetail` live, so a stale closure still queues the whole loaded playlist. Any future
row action that needs track data must read it live or become part of `==`.

### Menu content reads live services in its own body

`PlaylistTrackMenuContent` is a view, and the favorites/like lookups happen inside its body —
which SwiftUI evaluates when the menu is presented. The list itself no longer observes
`FavoritesManager`, so pinning a favorite elsewhere no longer rebuilds the visible window. The
same view backs both the context menu and the trailing ellipsis menu.

### Artwork is decoded at display size and prefetched

Rows pass `PlaylistTrackRow.thumbnailSize` (40×40; `ImageCache` doubles it for Retina) so the
cache stops decoding 320×320 bitmaps per row. The view also prefetches the artwork of the
upcoming rows via `ImageCache.shared.prefetch(urls:targetSize:maxConcurrent:)`, keyed by
track count so it re-runs per page, matching the pattern documented in
[architecture.md](../architecture.md).

### Entrance animation is initial-page only

Rows past the first page appear instantly, and `staggeredAppearance` gained an `itemId`
parameter so animated rows are keyed by `videoId` instead of position.

### Hover highlighting is suspended while scrolling

The list watches `onScrollPhaseChange` and passes `isScrolling` into the row, which disables
`InteractiveRowStyle`'s hover highlight for the duration of the gesture. This uses the native
scroll-phase API rather than a `simultaneousGesture`, so nothing competes with the scroll
gesture itself.

### Paging is driven by scroll proximity, with one page of headroom

`loadNextPage(showIndicator:)` is the single entry point. It coalesces concurrent callers
through one in-flight task, so a prefill and a scroll-triggered load never issue two
continuation requests against the same token. After a page of the list loads, one further page
is prefetched in the background (`prefillNextPage`), and the view requests the next page from
`onScrollGeometryChange` when the user comes within `paginationThreshold` (1200 pt) of the
bottom, bucketed so a short page still re-triggers on the next nudge.

This replaces the row-level `.onAppear` trigger, which fired at the true bottom of the list —
too late for the fetch, and with the spinner inside the visible window. Proximity in points is
independent of row height, which keeps album and playlist layouts equivalent. Deduplication now
maintains `loadedVideoIds` incrementally instead of rebuilding a set of every loaded track per
page, and a cancelled page (refresh or navigation) no longer mutates state because
`appendNextPage` checks `Task.isCancelled` after its await.

## Consequences

### Positive

- Player, favorites, and library updates now invalidate two rows instead of every realized row.
- Thumbnail decode work per row drops by roughly the ratio of the sizes, and the serialized
  `ImageCache` actor is no longer a scroll-path bottleneck.
- Newly realized rows during a fling have no animation, no hover transaction, and their artwork
  is usually already warm.
- Scroll cost is now decoupled from how complex a row is: the rich row and a minimal stand-in
  measured the same order of magnitude, where the `LazyVStack` version cost ~10× the stand-in's
  tail (p95 49.2 ms vs 4.7 ms, 43/240 vs 5/240 passes over 8 ms).
- Scrolling never waits on a continuation request, and the loading spinner stays below the fold.
- Row behaviour is unit-testable in isolation, and `PlaylistDetailViewModel` is covered by tests
  for prefill depth, request coalescing, cross-page dedupe, and refresh cancelling a stale page.

### Negative

- `PlaylistTrackRow.==` is hand-written and must be kept in step with the row's body. A missed
  field silently freezes that part of the UI.
- The row cannot take a captured `[Song]` snapshot for its actions; new actions must read live
  state, which is less convenient than passing the array down.
- One extra page is fetched per page of scrolling (~100 tracks when idle at the first page),
  trading a small amount of bandwidth and memory for smoothness.
- `PlaylistDetailViewModel` gained a `prefetchesFollowingPage` flag so tests can keep page
  accounting deterministic.

### Neutral

- `PlaylistTrackRow` remains an `Equatable` view applied with `.equatable()`. That is no longer
  the scroll fix it was meant to be; it is kept because it still avoids rebuilding row bodies for
  unrelated app state, and the cost it adds is one view per row.
- The remaining large lists (`HomeView`, `SearchView`, `ChartsView`, `QueueView`, the favourites
  carousels) still use `ScrollView` + `LazyVStack`, and `HomeSectionItemCard` still tracks hover
  per card. The mechanism measured here applies to them unchanged; they are out of scope for this
  ADR, and each needs its own row-level design pass because their rows are not table rows.
- `List` applies its own row metrics and selection model, so row chrome (insets, separators,
  background) is set explicitly rather than inherited.

## References

- [architecture.md — Performance Guidelines](../architecture.md)
- [common-bug-patterns.md — Pre-Submit Checklists](../common-bug-patterns.md)
- ADR-0008: Nonisolated Network Helpers for MainActor Classes (main-actor parsing stays on the
  main actor; this ADR only moves pure bookkeeping off the scroll path)
