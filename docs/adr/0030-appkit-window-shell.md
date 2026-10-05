# ADR-0030: AppKit Window Shell (Split View + App-Owned Toolbar)

## Status

Accepted

## Context

Kaset's window has two sidebars: the navigation sidebar on the left, and — with the Now Playing
sidebar design enabled ([ADR-0029](0029-now-playing-sidebar.md)) — the artwork column on the right.
The window is SwiftUI, and its layout was a `NavigationSplitView` with an `HStack` beside it, so only
the *navigation* sidebar was a column the platform knew about.

That produced a defect with no SwiftUI fix. **A macOS window has one toolbar, and SwiftUI positions a
view's `ToolbarItem` against the window, not against the view.** With a sidebar in the middle of the
window:

- `.automatic` items pin to the window's trailing edge — which is *over* the right sidebar, so a
  playlist's search/sort/refresh landed on top of it;
- macOS 26 draws one glass capsule behind a run of items that share a placement, so a toggle next to a
  search field became a single stretched pill;
- there is no `ToolbarItemPlacement` that means "the trailing edge of this view", and no way to declare
  a second tracking separator.

Three fixes were tried and rejected:

1. **Reserving the column's width with a transparent toolbar item.** It moved the controls but macOS 26
   drew the reservation as an empty glass capsule the width of the sidebar. A custom `NSView`-backed
   spacer was absorbed into the same capsule.
2. **Moving the controls into the page** (`PageTrailingControls`, the page's first row). It cannot be
   covered — but it is a workaround, it scrolls away, and it is not where a macOS app puts them.
3. **`.inspector`** for the column. The inspector nests a second `NSSplitViewController` inside the
   `NavigationSplitView`, and resizing that nested controller invalidates constraints re-entrantly
   during the display cycle, which aborts the app (`_postWindowNeedsUpdateConstraints` →
   `objc_exception_rethrow`).

The platform's mechanism for exactly this problem is `NSTrackingSeparatorToolbarItem`: a separator that
sits on a split view's divider and moves with it, so the items before it are laid out against the region
to its left. It is what Finder, Mail and Notes use to keep their content clear of the inspector. It
needs a real `NSSplitView` with a real divider to track, and it is inserted through `NSToolbarDelegate` —
SwiftUI exposes no such item and no such placement.

## Decision

**The window is AppKit's — an `NSWindow` the `AppDelegate` creates, hosting `MainWindow` — and the
window's layout is AppKit's too: one `NSSplitViewController` with three panes, each hosting SwiftUI. The
toolbar is the app's own `NSToolbar`, with the app's `NSToolbarDelegate`.**

```
AppDelegate.installMainWindow()
└── NSWindow  (contentViewController = NSHostingController(rootView: MainWindow))
    ├── window.toolbar = NSToolbar(delegate: WindowToolbarController)
    │     .toggleSidebar ─ .sidebarTrackingSeparator ─ …page items… ─ .inspectorTrackingSeparator ─
    │     .flexibleSpace ─ .nowPlaying (the column's toggle, in the region above the column)
    └── WindowShell (NSViewControllerRepresentable)
        └── WindowShellController (NSSplitViewController)
            ├── NSSplitViewItem(sidebarWithViewController:)    → Sidebar(…)              [pane 0]
            ├── NSSplitViewItem(viewController:)               → the page               [pane 1]
            └── NSSplitViewItem(inspectorWithViewController:)  → NowPlayingSidebarView  [pane 2]
```

The `Window` scene is gone from `KasetApp.body`; only the `Settings` scene remains SwiftUI's, and the
commands are attached to it. The view the scene used to declare is built by `KasetApp.makeRootView()` and
handed to the delegate in `init`.

A real `sidebarWithViewController:` item and a real `inspectorWithViewController:` item are what AppKit's
standard `NSToolbarSidebarTrackingSeparatorItemIdentifier` and
`NSToolbarInspectorTrackingSeparatorItemIdentifier` *discover* and align themselves to — nothing has to be
measured or positioned by the app. AppKit then supplies, for free, everything the previous design had
hand-rolled:

| Owed by the app before | Now |
|---|---|
| a resize handle view, its cursor, its hit area | `NSSplitView` divider |
| a divider-drag observer, a debounce, a commit path | `NSSplitViewItem` thickness bounds |
| width clamping, a floor width, a ceiling | `minimumThickness` / `maximumThickness` |
| persisting the width, restoring it | `NSSplitView.autosaveName` |
| window-minimum arithmetic that tracked the column | the items' own minimum widths — see "The window's minimum is the panes' again" below, which this revision had to reinstate |
| a collapse animation | `toggleInspector(_:)` / `toggleSidebar(_:)` |
| a window-wide toolbar reservation | `NSTrackingSeparatorToolbarItem` |

### Ownership rules

- **The main window is the app's `NSWindow`, created by `AppDelegate.installMainWindow()`.** This is
  forced by the toolbar. Growing out of the previous revision:
  1. A SwiftUI-owned window cannot carry the app's toolbar. SwiftUI's window controller owns the toolbar
     it installs and rewrites that toolbar's item list from its own content on every constraint pass.
  2. Handing SwiftUI's own toolbar the app's items therefore does not survive — the items were wiped a
     pass after they were stated and the titlebar came back with no controls in it at all.
  3. Installing the app's own `NSToolbar` on a SwiftUI-owned window works visually, but leaves SwiftUI's
     window controller holding key-value observations on a toolbar that is no longer in the window. Its
     next `AppKitWindowController.updateToolbarIfNeeded` — which runs from
     `NSHostingView.updateConstraints`, i.e. inside a display-cycle constraint pass — removes an observer
     it is not registered on, `-[NSObject removeObserver:forKeyPath:]` raises, and AppKit turns the
     exception escaping a constraint pass into `+[NSApplication _crashOnException:]` and a `SIGTRAP`.
  An `NSWindow` the app makes itself has no SwiftUI window controller at all: nothing rewrites the
  toolbar, nothing observes it, and the shell's `WindowToolbarController` owns it outright. The window
  carries the app's chrome (`fullSizeContentView`, a transparent titlebar with no separator), keeps the
  delegate that hides it on close instead of closing it, and persists its frame under
  `KasetMainWindow`.
- **The root view is built from plain state, never from `@State`.** Because the window is AppKit's, that
  view is built in `KasetApp.init` — and a `@State` read outside a view/scene body is not a read. SwiftUI
  says so at runtime: *"Accessing State's value outside of being installed on a View"*, then hands back a
  **constant binding** from the projection and creates a **new instance each time** for a value. The first
  is what stopped the navigation sidebar's selection responding (its binding never wrote anywhere); the
  second handed the window services that were not the app's, which left `MainWindow` on its
  *initializing* branch — no `WindowShell`, and therefore no toolbar at all. So the services are plain
  stored properties, and the window's own UI state (navigation selection, search-focus trigger, command
  bar, What's New) is an `@Observable` `AppWindowState` the app builds real `Binding`s from.
- **The toolbar is the app's own `NSToolbar`.** The install is deferred by one main-actor turn and a
  recreated shell controller takes over the toolbar this app already installed (matching its identifier)
  rather than replacing it, because `NSToolbar.delegate` is weak and the previous delegate may be gone.
  Its items are stated **before** the toolbar goes into the window: an `NSToolbar` starts empty, and the
  window draws what is attached, so an empty toolbar put into the window is a titlebar with no controls
  in it at all.
- **The page's back control is the app's, for the same reason.** The one item SwiftUI's replaced toolbar
  carried was `com.apple.SwiftUI.navigationStack.back` — the back button a pushed page needs — so taking
  that toolbar back took the reader's only way out of the page with it (reported as "the other buttons are
  there but the back button disappears"). A page's stack therefore states what it is the only thing that
  knows: whether it can be popped, and how (`PageNavigationModel`). `PageNavigationStack` is a
  `NavigationStack` plus that statement, and it takes the page's own `NavigationPath` binding, so every
  push already in the app — links, `navigationDestination`, a page appending to its path — is untouched.
  The item is drawn only while the page says it can pop, and `goBack()` will not run an action whose page
  has been replaced.
- **The window title yields the page region's leading slot to that back control.** Ordering the item
  first in `WindowToolbarItems.identifiers` is not enough to place it there: AppKit draws the window's
  title as a flexible view at the *leading* edge of the region right of the sidebar's tracking separator
  and lays the region's items out after it. Measured in a reproduction of this window (1240pt, the app's
  item order and install state), the first page item sat at x=740 — immediately left of the Ask AI button
  and the page's own controls, which is the "the back button is with the other controls on the right"
  report — and moved to x=224, the region's own leading edge, with the title hidden. So
  `WindowShellController.applyTitleVisibility` hides the title while the page has a back control and
  restores it at a page root, where nothing has to lead. It never un-hides while the toolbar itself is
  hidden, because the fullscreen Now Playing experience hides both and that state belongs to
  `MainWindow`. Verified in the running app: with a back control published, the item renders at x=244,
  right of the sidebar's divider, with `titleVisibility=hidden`.
- **The toolbar is re-taken whenever something else puts its own in the window.** "The app's `NSToolbar`"
  is not the same as "the window's toolbar", and on macOS 26 nothing keeps the two together. SwiftUI's
  window controller replaces the window's toolbar while the pages navigate — the reader opening an album
  or a playlist takes its own one-item toolbar, and coming back out of it takes the toolbar away
  entirely (`window.toolbar = nil`). Either way the titlebar is left with no sidebar toggle, no page
  controls and no Now Playing toggle, and stays that way until the app states its toolbar again. That used
  to be the next layout or appearance pass, which is how the reader could see the bar come back after a
  beat — or not see it come back at all. The shell therefore observes `NSWindow.toolbar` (there is no
  notification for it) and reinstalls on the next main-actor turn, which is outside AppKit's own change
  callback. Verified in the running app: a push logs `Toolbar takeover: … window=other identifier= items=1`
  and a pop logs `… window=nil`, each restored immediately (`Toolbar replaced, restoring the app's: …`).
  The durable fix is still the one this ADR already chose the AppKit window for: the pages should stop
  asking SwiftUI for toolbar-managed content (`navigationTitle` on a page inside the shell is what gives
  SwiftUI's controller a reason to manage one), with the window title stated by the shell instead.
- **The window's chrome is re-asserted from the layout pass.** The app sets it when it creates the window,
  so this is normally a no-op; it is kept because only values that actually differ are written, and it
  means anything that takes the window over later cannot leave the reader's sidebar rendering as an
  opaque band above a sidebar.
- **The panes reach the window's top.** `WindowShell` is laid out `.ignoresSafeArea(.container, edges:
  .top)` and AppKit then gives each pane a 52pt top safe area, which is what makes the *backdrops* — the
  navigation sidebar's material and the Now Playing column's artwork — run to the window's top edge while
  each pane's own content still lays out below the toolbar. That is the whole reason the titlebar reads as
  part of the sidebar rather than as a band above it.
- **The app states only what is its decision:** whether the Now Playing sidebar is open (app state, from
  which the pane's collapse is derived) and the width it opens at the first time. A collapse the reader
  performs — the toolbar toggle, a drag, a double-click on the divider — is observed on the item's
  `isCollapsed` and fed back into app state, and the app's own writes are flagged so they are not read
  back as a reader's action. **With the setting on, the column is open at launch**, so the choice of
  design is also the choice of what the window opens with: `PlayerService.init` states it before the
  window is created from it.
- **The window's minimum is the panes' again, and the page is no longer the pane that gives way.** This
  revision first stated the opposite: the panes' minimums add up to more than the window's own 900pt
  floor, so the *page* was allowed to shrink (down to a stated `squeezedContentWidth` of 320) and the
  window's minimum was left where it was. Measured in the running app, that is the pair of reports this
  ADR's successor fixes. The split view sizes itself to its **content**, not to the items'
  `minimumThickness`: with the Now Playing column open it laid itself out at 200 + **765** + 300 = 1265
  while the window was 1182 wide (and 900 before that), so the page was drawn as much as 365pt past the
  window's edge and cut off — logged as `Shell overflow: the split view is 1265 wide in a 1182pt
  window (page=765 pageMin=680 columnOpen=true)`. 765 is the page's real minimum: what the player bar's
  own controls need, and the reason the bar now lays its controls out in both hover states (an `if`
  there made the page's, the split view's and the window's minimum a function of the pointer — the split
  view grew 65pt on hover, past the window, and dropped back on un-hover). So the app states the
  arithmetic again, in one place: `WindowShellLayout.minimumWindowWidth(tracksColumn:)` — the panes'
  minimums plus the dividers, never below the 900pt floor — written to the window and stated again on
  `MainWindow`'s content; the *side panes'* maxima give way instead
  (`WindowShellLayout.sidebarMaximum` / `inspectorMaximum`, each capped at what is left once the page
  and the other pane have theirs); and a window narrower than its minimum is grown to it once. Verified
  in the running app at the column's minimum: window 1267, split 1267, panes 200/767/300, `overflow=false`
  at every width swept, and identical while the player bar was hovered. The cost is a larger minimum than
  this ADR originally chose — 967 with the column closed, 1267 with it open — and the page's 765 is the
  term that sets it; making the player bar able to compress is what would bring it back down.
- **The navigation sidebar brings its own surface.** `NavigationSplitView` used to supply a sidebar
  material for the sidebar's SwiftUI to sit in. With the split view gone, the pane supplies it again
  (`SidebarMaterialPane`: an `NSVisualEffectView` with the `.sidebar` material and the sidebar's SwiftUI
  hosted inside it).
- **The sidebar's rows are tagged rows, not navigation links.** The sidebar used to be a
  `NavigationSplitView`'s sidebar, and its rows were `NavigationLink(value:)`s. This shell replaced that
  split view, and a `NavigationLink` whose value has no navigation container left to navigate renders its
  label in the **inactive** style. It cost far more to find than it should have, because the failure looks
  exactly like a colour problem and never says so: the row's rendered ink measures **0.498** against
  **0.000** for the same row as a plain tagged row — reproduced both inside the sidebar's material and
  without it — while every `foregroundStyle` on the link's label, a literal `Color.black` included, is
  ignored. `MainWindow`'s page has always been driven by the list's own `selection` binding, which is what
  the links' `value` was feeding anyway (`Sidebar.navigationRow(_:)`), so nothing was lost by dropping
  them. `WindowShell`'s `Sidebar ink:` line measures the rendered result.
- **The sidebar draws in a *vibrant* appearance.** The content inside the material resolves its colours
  against `NSAppearanceNameVibrantLight` / `VibrantDark`, where the system colours are not the
  full-contrast ones: `NSColor.labelColor` is black at **0.70** alpha under `VibrantLight` against
  **0.85** under `Aqua` (measured). `.primary` *is* `labelColor`, so it cannot escape that, and the
  appearance cannot be overridden from inside the pane (moving the content beside the material and setting
  an explicit appearance were both tried — the hosting view came back vibrant either way). So the
  sidebar's own text states a **literal** colour (`Sidebar.rowForeground(for:)`) and the shell's
  `Sidebar surface rows:` line publishes the appearance and the resolved label colour. This is a
  second-order effect, not the grey the rows showed — that was the navigation links above. The same
  vibrant appearance is why a source-list row's *selection* needed its emphasis put back in step
  (`SidebarBackingStyleConfigurator`).
- **The window is a clear sheet, so the sidebar's material is a real macOS sidebar.** The effect view
  uses `blendingMode = .behindWindow`, which is what makes the column sample the desktop the way Finder's
  and Mail's do. That requires the window to be non-opaque with no background of its own (`isOpaque =
  false`, `backgroundColor = .clear`, re-asserted from the layout pass with the rest of the chrome) —
  otherwise the material has only the window's own background to composite against and `.sidebar` renders
  as a flat grey layer over the column, which is the symptom this removes. The cost is that every pane
  which *is* a surface must now say so: the page paints `windowBackgroundColor` (bleeding up under the
  toolbar) and the Now Playing column paints its artwork wash, so the translucency belongs to the
  sidebar alone.
- **The sidebar's `List` must not paint its own background.** `NavigationSplitView` used to supply the
  surface, and with it a list whose background was transparent. A standalone `List` with
  `.listStyle(.sidebar)` draws its own opaque background *on top of* whatever the pane puts behind it,
  which is why supplying a material changed nothing until `Sidebar`'s list took
  `.scrollContentBackground(.hidden)`.
- **Collapse happens by unmounting the pane's content, not by the item alone.** `NowPlayingSidebarView`'s
  lyrics polling and canvas loading start and stop with the view's lifetime, so the inspector pane renders
  `Color.clear` while closed even though AppKit also has the pane collapsed.

### What is deliberately not done

No custom divider, no custom resize cursor, no custom width persistence, no custom collapse animation, and
no view-tree walking to *find* the split view or its divider: the shell hands its own split view to the
toolbar's controller. Each of those was in the previous design and each was a bug farm.

## Consequences

**Easier**

- Toolbar items land where a macOS app puts them, at any window size and any column width, without the app
  positioning anything: the page's items are bounded by the inspector separator, and the region after it —
  the column's own controls — is the only place anything can land on the column.
- Both sidebars collapse, resize and remember their widths through the platform, including the standard
  View-menu/toolbar toggle for the navigation sidebar and full-height sidebar material.
- The Now Playing column's artwork is genuinely flush to the window's top, behind the toolbar, because the
  column's own pane reaches the top.

**Harder / accepted trade-offs**

- `KasetApp.body` no longer has a `Window` scene, so the app's menu bar is built from the `Settings`
  scene's commands alone. SwiftUI aggregates commands from the scenes in the body, so this is the same set
  of menus as before — but it is the one thing about this change that only a launch can confirm.
- The window's structure is AppKit, so it is beyond what a SwiftUI preview or a snapshot test can cover:
  the shell's own behaviour is verified by running it and reading the window's view tree (the previous
  `MainWindow` layout was likewise untestable).
- `NSSplitViewController` enforces rules that are easy to trip: it owns its split view's delegate and
  subviews, so overriding `loadView` or replacing them breaks the controller.
- The toolbar's item list is a value (`WindowToolbarItems.identifiers`) rebuilt only when it changes,
  because assigning `itemIdentifiers` on every SwiftUI update re-lays-out the toolbar.
- A pushed page trades the titlebar's title for its back control (see the leading-slot point above). The
  page's own content carries the title — every detail page draws its own header — so nothing is lost that
  the reader does not have in front of them, but the titlebar text is not there while the control is.
- The app and SwiftUI take turns owning the window's toolbar, once per navigation into (and back out of)
  a page that states a `navigationTitle`. The app wins, within the same run loop turn, but the toolbar
  object is replaced each time — accepted for now because the alternative is removing `navigationTitle`
  from the pages, which is where the window's title currently comes from.
- Two bordered controls are never adjacent: macOS 26 fills one glass capsule behind a contiguous run of
  items, so the Ask AI button and the page's own controls are separated by an `NSToolbarItem.Identifier
  .space`. Without it they were drawn as one stretched pill.
- A page's controls reach the toolbar through a contribution the *page* publishes, not through anything the
  page declares declaratively: a page states what belongs in the titlebar for as long as it is the page on
  screen (`PageToolbarModel`), and the controls are hosted SwiftUI reading the page's model — so they are
  only as live as that model is. State a toolbar control needs therefore lives on the model rather than in
  the page's `@State` (see [ADR-0029](0029-now-playing-sidebar.md)).
