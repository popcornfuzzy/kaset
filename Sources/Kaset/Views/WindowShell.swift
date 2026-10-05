import AppKit
import os
import SwiftUI

// MARK: - WindowShellLayout

/// The window's column arithmetic: the bounds AppKit's split view items enforce, and the name its
/// autosave is written under.
///
/// A value type so the numbers the app says it wants and the numbers AppKit enforces are one statement
/// — the split items take their minimum and maximum thickness straight from here.
@available(macOS 26.0, *)
struct WindowShellLayout: Equatable {
    /// Bounds of the navigation sidebar. These are the numbers the sidebar used to state with
    /// `.navigationSplitViewColumnWidth(min:ideal:max:)`, and `minContentWidth` still counts the old ideal
    /// so the window's minimum total is the number it always was.
    var minSidebarWidth: CGFloat = 200
    var maxSidebarWidth: CGFloat = 300

    /// Minimum width of the page itself.
    ///
    /// The navigation sidebar is laid out *beside* this now, so this is the page's own width — not
    /// `detailMinWidth`, which counted the sidebar as part of the detail area. It is a floor the page is
    /// held to at every window width: a page squeezed below this is the page's controls cropped, which is
    /// what the window used to do to it (see `minimumWindowWidth(tracksColumn:)`).
    var minContentWidth: CGFloat = 680

    /// The width the window's owner states for it, independent of which panes are open.
    ///
    /// The window's minimum is this or the panes' own sum, whichever is larger: `MainWindow` states it as
    /// the window's old `detailMinWidth`, so the floor the app has always had is kept, and the panes only
    /// raise it when they genuinely need the room.
    var minWindowWidth: CGFloat = 900

    /// The width AppKit's split view puts between two panes.
    ///
    /// `dividerStyle = .thin` is one point. Stated here so the window's minimum and the panes' limits are
    /// one piece of arithmetic rather than one number that reads the split view and another that cannot.
    static let dividerThickness: CGFloat = 1

    /// The window's minimum **content** width for a given column state.
    ///
    /// The panes' own minimums plus the dividers. The page never gives up `minContentWidth`, which is the
    /// point: the window used to satisfy a small window by shrinking the page instead — down to a stated
    /// `squeezedContentWidth` of 320 — and a split view cannot satisfy a requirement larger than its own
    /// width, so what AppKit did with the leftover was break a constraint and draw the page past the
    /// window's edge. Opening the column therefore asks for a window wide enough to hold it rather than
    /// making the page give way.
    func minimumWindowWidth(tracksColumn: Bool) -> CGFloat {
        let column = tracksColumn ? self.minInspectorWidth : 0
        let panes = self.minSidebarWidth + self.minContentWidth + column + (2 * Self.dividerThickness)
        return max(self.minWindowWidth, panes)
    }

    /// How wide the navigation sidebar may be at a given split width.
    ///
    /// What is left once the page's minimum and the Now Playing column have been given theirs, so the three
    /// panes always add up and AppKit is never handed a requirement it cannot satisfy. Never below the
    /// sidebar's own minimum, which is what makes it a limit rather than a squeeze. The other panes' own
    /// **current** widths are the inputs, which is what keeps the two maxima consistent with each other:
    /// stated against their minimums instead, two panes could each sit inside their own cap and still not
    /// fit together.
    func sidebarMaximum(splitWidth: CGFloat, inspectorWidth: CGFloat, columnOpen: Bool) -> CGFloat {
        let column = columnOpen ? inspectorWidth : 0
        let room = splitWidth - self.minContentWidth - column - (2 * Self.dividerThickness)
        return max(self.minSidebarWidth, min(self.maxSidebarWidth, room))
    }

    /// How wide the Now Playing column may be at a given split width (see `sidebarMaximum`).
    func inspectorMaximum(splitWidth: CGFloat, sidebarWidth: CGFloat) -> CGFloat {
        let room = splitWidth - self.minContentWidth - sidebarWidth - (2 * Self.dividerThickness)
        return max(self.minInspectorWidth, min(self.maxInspectorWidth, room))
    }

    /// Bounds of the Now Playing sidebar.
    var minInspectorWidth: CGFloat = 300
    var maxInspectorWidth: CGFloat = 560

    /// AppKit persists the divider positions — and whether the panes are collapsed — under this name,
    /// so the window comes back the way the reader left it without the app tracking any of it.
    var autosaveName: String = "Kaset.MainSplitView"
}

// MARK: - WindowShell

/// The window's own layout: **one** `NSSplitViewController` with three panes — the navigation sidebar,
/// the page, and the Now Playing sidebar — each hosting SwiftUI.
///
/// ## Why the window is AppKit's
///
/// A macOS window has one toolbar, and a view's `ToolbarItem` is positioned against the *window*: with a
/// sidebar in the middle of the window there is no placement, spacer or order that keeps the page's own
/// controls off it. The platform's mechanism is a **tracking separator** — a separator that sits on a
/// split view's divider and moves with it, so the items before it are laid out against the region to its
/// left. That is how Finder and Mail keep their content clear of the inspector, and it needs a real
/// `NSSplitView` with a real divider to track.
///
/// SwiftUI only ever inserts one tracking separator, for the navigation sidebar, and exposes no
/// `ToolbarItemPlacement` for a second. So the shell is AppKit, and the toolbar is the app's own
/// `NSToolbar` (see `WindowToolbarController`) — installed by this controller because it is the object
/// that owns the split view the separators track.
///
/// ## What AppKit now provides
///
/// - `sidebarWithViewController:` / `inspectorWithViewController:` items, which *are* the sidebar and the
///   inspector AppKit's standard `NSToolbarSidebarTrackingSeparatorItemIdentifier` /
///   `NSToolbarInspectorTrackingSeparatorItemIdentifier` discover and align to.
/// - Collapse: `NSSplitViewController.toggleSidebar(_:)` / `toggleInspector(_:)` and the items' own
///   `canCollapse`, with the animation.
/// - The divider drag, its cursor, and the clamping to each item's minimum and maximum thickness — which
///   is why the app no longer has a resize handle, a divider observer or any width arithmetic.
/// - Persistence: `splitView.autosaveName`.
///
/// The app keeps only what is genuinely *its* decision: whether the Now Playing sidebar is open (that is
/// app state, and the pane's content is a function of it) and the width it opens at the first time.
@available(macOS 26.0, *)
struct WindowShell: NSViewControllerRepresentable {
    /// The three panes, already built where the SwiftUI environment they need is in scope.
    let sidebar: AnyView
    let content: AnyView
    let inspector: AnyView

    let layout: WindowShellLayout

    /// Whether the Now Playing sidebar is open. The app's page state is the source of truth, so the pane
    /// is collapsed or expanded from here; a collapse the reader performs comes back through
    /// `onInspectorCollapsedChange`.
    let showsInspector: Bool
    /// Width the Now Playing sidebar opens at the first time the app runs; AppKit's autosave owns it from
    /// then on.
    let seedInspectorWidth: CGFloat
    let onInspectorCollapsedChange: (Bool) -> Void

    /// What the window's toolbar shows.
    let toolbar: WindowToolbarItems

    func makeNSViewController(context _: Context) -> WindowShellController {
        let controller = WindowShellController()
        controller.apply(
            sidebar: self.sidebar,
            content: self.content,
            inspector: self.inspector,
            layout: self.layout,
            state: WindowShellState(
                showsInspector: self.showsInspector,
                seedInspectorWidth: self.seedInspectorWidth
            ),
            toolbar: self.toolbar,
            onInspectorCollapsedChange: self.onInspectorCollapsedChange
        )
        return controller
    }

    func updateNSViewController(_ controller: WindowShellController, context _: Context) {
        controller.apply(
            sidebar: self.sidebar,
            content: self.content,
            inspector: self.inspector,
            layout: self.layout,
            state: WindowShellState(
                showsInspector: self.showsInspector,
                seedInspectorWidth: self.seedInspectorWidth
            ),
            toolbar: self.toolbar,
            onInspectorCollapsedChange: self.onInspectorCollapsedChange
        )
    }
}

// MARK: - WindowShellState

/// The parts of the shell that are the app's decision rather than AppKit's.
@available(macOS 26.0, *)
struct WindowShellState: Equatable {
    var showsInspector: Bool
    var seedInspectorWidth: CGFloat
}

// MARK: - ShellPane

/// Hosts a pane's SwiftUI and hands its size to it **in the same layout pass**.
///
/// The Now Playing sidebar sizes its artwork and its embedded queue table to the column, and the divider
/// moves that column continuously. A size measured out of the layout (`.onGeometryChange` into `@State`)
/// arrives on the *next* pass, so every frame of a drag drew stale content: the artwork and the queue
/// column lagged the divider they belonged to, which is what made the drag look like the contents were
/// tearing away from their own width.
///
/// A `GeometryReader` is a layout container, so its child is built with the size being resolved rather
/// than a value remembered from the previous pass. The reader fills whatever the split view hands it, so
/// it never becomes an intrinsic size the divider would have to negotiate with.
///
/// The pane's top safe area comes from the same reader: it is AppKit's toolbar inset for the pane, the
/// band the column's backdrop is drawn under and its content is inset by, and reading it here keeps a
/// pane's whole geometry one statement from one pass.
@available(macOS 26.0, *)
struct ShellPane<Content: View>: View {
    @ViewBuilder var content: (_ size: CGSize, _ topInset: CGFloat) -> Content

    var body: some View {
        GeometryReader { proxy in
            self.content(proxy.size, proxy.safeAreaInsets.top)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }
}

// MARK: - WindowShellController

/// The three-pane split controller behind `WindowShell`, and the owner of the window's toolbar.
///
/// Note what it does *not* do: it never sets the managed split view's delegate or subviews, and it
/// touches only `vertical`, `dividerStyle` and `autosaveName` on it — anywhere else and
/// `NSSplitViewController` throws.
@available(macOS 26.0, *)
@MainActor
final class WindowShellController: NSSplitViewController {
    let sidebarController = NSHostingController(rootView: AnyView(EmptyView()))
    let contentController = NSHostingController(rootView: AnyView(EmptyView()))
    let inspectorController = NSHostingController(rootView: AnyView(EmptyView()))

    var onInspectorCollapsedChange: ((Bool) -> Void)?

    private let toolbarController = WindowToolbarController()

    private let logger = DiagnosticsLogger.ui

    private var sidebarItem: NSSplitViewItem?
    private var contentItem: NSSplitViewItem?
    private var inspectorItem: NSSplitViewItem?

    private var layout = WindowShellLayout()
    private var state = WindowShellState(showsInspector: false, seedInspectorWidth: 380)
    /// What the window's toolbar was last told to show (see `applyTitleVisibility`).
    private var toolbarItems = WindowToolbarItems(
        tracksColumn: false,
        showsAI: false,
        showsNowPlayingToggle: false,
        canGoBack: false,
        pageControls: nil,
        onBack: {},
        onAI: {}
    )
    /// Set while this controller writes the panes' own state, so the resulting KVO notification is not
    /// read back as a reader's action.
    private var isApplyingState = false
    private var needsStateApply = true
    private var hasSeededDivider = false
    private var pendingToolbarInstall: Task<Void, Never>?
    private var inspectorCollapseObservation: NSKeyValueObservation?
    /// Watches for anything putting its own toolbar in the window (see `observeToolbarTakeover`).
    private var toolbarObservation: NSKeyValueObservation?

    // MARK: - Diagnostics state

    /// Throttling for the layout log: one entry per meaningful width change, not one per layout pass.
    private var lastLoggedSplitWidth: CGFloat = .nan
    private var lastLoggedInspectorCollapsed = false
    private var hasLoggedLayout = false
    private var wasInLiveResize = false
    private var hasLoggedSidebarSurface = false
    private var sidebarSurfaceProbeAttempts = 0
    private var sidebarSurfaceSettledProbe: Task<Void, Never>?

    /// Whether the app has already placed the Now Playing divider at its first-run width. After that
    /// AppKit's autosave owns the position, so the app must never touch it again.
    private static let dividerSeededKey = "Kaset.MainSplitView.seeded"

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // The toolbar's Now Playing toggle runs *this* controller's AppKit inspector toggle, so the
        // column opens with AppKit's animation, AppKit's divider clamping and AppKit's own collapse
        // bookkeeping — the app only says which object the item's action is addressed to.
        self.toolbarController.onToggleNowPlaying = { [weak self] in
            self?.toggleInspector(nil)
        }
        self.configureSplitView()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if self.needsStateApply, self.isViewLoaded {
            self.needsStateApply = false
            self.applyStateToItems()
        }
        // The seed needs a real split view width, so it waits for the first layout that has one.
        if self.state.showsInspector, self.splitView.bounds.width > 0 {
            self.seedDividerIfNeeded()
        }
        self.applyWindowChrome()
        // The panes' limits depend on the width the split view actually has, so they are decided here and
        // re-asserted every pass, alongside the minimum the window itself is held to.
        self.applyPaneLimits()
        self.applyWindowMinimumSize()
        self.logLayoutIfNeeded()
        self.logSidebarSurfaceIfNeeded()
        self.installToolbar()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        self.installToolbar()
    }

    // MARK: - Inputs

    func apply(
        sidebar: AnyView,
        content: AnyView,
        inspector: AnyView,
        layout: WindowShellLayout,
        state: WindowShellState,
        toolbar: WindowToolbarItems,
        onInspectorCollapsedChange: @escaping (Bool) -> Void
    ) {
        // The panes are replaced every pass; SwiftUI diffs them.
        self.sidebarController.rootView = sidebar
        self.contentController.rootView = content
        self.inspectorController.rootView = inspector

        self.onInspectorCollapsedChange = onInspectorCollapsedChange
        self.toolbarItems = toolbar
        self.toolbarController.apply(items: toolbar, onAI: toolbar.onAI)
        self.applyTitleVisibility()
        // Every state this shell is handed is also a chance to notice that the window's toolbar is no
        // longer the app's. Repairing it here rather than only from a layout or appearance pass is what
        // keeps a toolbar something else put in the window from standing — empty — until the next time
        // AppKit happens to lay the window out.
        self.installToolbar()

        guard layout != self.layout || state != self.state else { return }
        let layoutChanged = layout != self.layout
        self.layout = layout
        self.state = state

        guard self.isViewLoaded else { return }
        self.needsStateApply = true
        if layoutChanged {
            self.applyStateToItems()
        } else {
            self.applyInspectorVisibility()
        }
    }

    // MARK: - Split view

    private func configureSplitView() {
        self.splitView.isVertical = true
        self.splitView.dividerStyle = .thin
        // Divider positions *and* collapse state are AppKit's to remember from here on.
        self.splitView.autosaveName = self.layout.autosaveName

        // A real sidebar and a real inspector, not two generic panes: these are the items AppKit's own
        // tracking separators discover and align to, and the ones `toggleSidebar:` / `toggleInspector:`
        // act on. Without that, the toolbar's items cannot be bounded by the columns at all.
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: self.sidebarController)
        sidebarItem.canCollapse = true
        sidebarItem.canCollapseFromWindowResize = false

        let contentItem = NSSplitViewItem(viewController: self.contentController)
        contentItem.canCollapse = false
        // The lowest holding priority: a window resize gives its space to the page, not to a sidebar.
        contentItem.holdingPriority = NSLayoutConstraint.Priority(249)

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: self.inspectorController)
        inspectorItem.canCollapse = true
        inspectorItem.canCollapseFromWindowResize = false
        // Just above the page's, so the column keeps the width the reader gave it when the *window* is
        // resized: without a stated priority the two flexible panes trade width arbitrarily, and the
        // column visibly lost its divider position on every window resize.
        inspectorItem.holdingPriority = NSLayoutConstraint.Priority(251)

        self.addSplitViewItem(sidebarItem)
        self.addSplitViewItem(contentItem)
        self.addSplitViewItem(inspectorItem)

        self.sidebarItem = sidebarItem
        self.contentItem = contentItem
        self.inspectorItem = inspectorItem

        // KVO rather than a split view delegate: the controller *is* the split view's delegate, and
        // replacing it throws.
        self.inspectorCollapseObservation = inspectorItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, change in
            MainActor.assumeIsolated {
                guard let self, let collapsed = change.newValue else { return }
                self.inspectorCollapseDidChange(collapsed)
            }
        }
    }

    /// Applies the thickness bounds and the app's visibility decision to the items.
    private func applyStateToItems() {
        guard let sidebarItem = self.sidebarItem,
              let inspectorItem = self.inspectorItem
        else { return }

        sidebarItem.minimumThickness = self.layout.minSidebarWidth
        sidebarItem.maximumThickness = self.layout.maxSidebarWidth
        // The page's minimum is stated in `applyPaneLimits` rather than here, and the side panes' *maxima*
        // are functions of the width the window has, so they live there too.
        inspectorItem.minimumThickness = self.layout.minInspectorWidth
        inspectorItem.maximumThickness = self.layout.maxInspectorWidth

        self.applyInspectorVisibility()
    }

    /// Collapses or expands the Now Playing pane from the app's own state.
    private func applyInspectorVisibility() {
        guard let inspectorItem = self.inspectorItem else { return }
        let shouldCollapse = !self.state.showsInspector
        if inspectorItem.isCollapsed != shouldCollapse {
            self.isApplyingState = true
            inspectorItem.isCollapsed = shouldCollapse
            self.isApplyingState = false
        }
        // All three follow every change to the column: the window's minimum is restated for the panes that
        // are now open, the window is made wide enough to hold them rather than left to squeeze the page,
        // and the side panes' limits are re-stated for the width that leaves.
        self.applyWindowMinimumSize()
        self.growWindowToMinimumIfNeeded()
        self.applyPaneLimits()
    }

    /// Grows the window to the minimum the panes need, when it is narrower than that.
    ///
    /// Opening the Now Playing column adds a 300pt pane, and a frame restored from a build whose arithmetic
    /// was different can be narrower than the panes need either way. The alternative to growing is a split
    /// view drawn past the window's edge (see `applyPaneLimits`), so the window is resized to its own
    /// minimum, keeping its top-left corner. It only ever *grows*, and only to that minimum: a frame the
    /// reader chose that is wide enough is left exactly as they left it, and a reader's divider drag never
    /// resizes the window under them.
    private func growWindowToMinimumIfNeeded() {
        guard let window = self.view.window else { return }
        let minimum = self.layout.minimumWindowWidth(
            tracksColumn: self.inspectorItem?.isCollapsed == false
        )
        guard window.contentLayoutRect.width < minimum - 0.5 else { return }

        var frame = window.frame
        let chrome = window.frame.width - window.contentLayoutRect.width
        frame.size.width = minimum + chrome
        // Narrowed to the space the screen actually has, so a small display gets the width it can rather
        // than a window hanging off the edge.
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x -= max(0, frame.maxX - visible.maxX)
            frame.size.width = min(frame.size.width, visible.width)
        }
        window.setFrame(frame, display: true, animate: false)
        let message = "Shell window widened to its minimum: content=\(Int(window.contentLayoutRect.width)) "
            + "minimum=\(Int(minimum)) columnOpen=\(self.inspectorItem?.isCollapsed == false)"
        self.logger.info("\(message, privacy: .public)")
    }

    /// The panes' limits: the page's minimum, and how wide either side pane may be right now.
    ///
    /// The page's minimum is a **floor**, held at every window width — it is not a function of the room
    /// that is left, which is what it used to be. Shrinking it was how the window stayed small, and a page
    /// squeezed to the old `squeezedContentWidth` of 320 is a page whose controls are cut off.
    ///
    /// What gives way instead is the *side panes' maxima*: each is capped at what is left once the page
    /// and the other pane have been given theirs, so the three panes always add up to the split view and
    /// AppKit is never handed a requirement it cannot satisfy (its answer to one is to break a constraint
    /// and draw a pane past the window's edge). The caps are read from the panes' **current** widths, which
    /// is what keeps them consistent with each other — with the minimums of the other pane, two panes could
    /// each be within their own cap and still not fit together. Clamping only ever narrows a pane and never
    /// below its minimum, so the pass settles rather than oscillating.
    private func applyPaneLimits() {
        guard let contentItem = self.contentItem,
              let sidebarItem = self.sidebarItem,
              let inspectorItem = self.inspectorItem
        else { return }

        contentItem.minimumThickness = self.layout.minContentWidth

        let splitWidth = self.splitView.bounds.width
        guard splitWidth > 0 else { return }

        let panes = self.splitView.arrangedSubviews
        let sidebarWidth = panes.first?.frame.width ?? self.layout.minSidebarWidth
        let inspectorWidth = panes.count > 2 ? panes[2].frame.width : 0
        let columnOpen = !inspectorItem.isCollapsed

        let sidebarMaximum = self.layout.sidebarMaximum(
            splitWidth: splitWidth,
            inspectorWidth: inspectorWidth,
            columnOpen: columnOpen
        )
        let inspectorMaximum = self.layout.inspectorMaximum(
            splitWidth: splitWidth,
            sidebarWidth: sidebarWidth
        )

        // A pane drawn past the window is the whole symptom this arithmetic exists to prevent, and it is
        // invisible in the app's source: the split view is told one width and lays itself out at its own
        // minimum instead. So it is reported rather than left to be seen. Seeing it means the page's content
        // needs more than `minContentWidth` states (`MainWindow.Layout.pageMinWidth`, measured at 765).
        if let window = self.view.window {
            let contentWidth = window.contentLayoutRect.width
            if contentWidth > 0, splitWidth > contentWidth + 0.5 {
                let overflow = "Shell overflow: the split view is \(Int(splitWidth)) wide in a "
                    + "\(Int(contentWidth))pt window (page=\(Int(panes.count > 1 ? panes[1].frame.width : 0)) "
                    + "pageMin=\(Int(self.layout.minContentWidth)) columnOpen=\(columnOpen))"
                self.logger.warning("\(overflow, privacy: .public)")
            }
        }

        guard sidebarItem.maximumThickness != sidebarMaximum
            || inspectorItem.maximumThickness != inspectorMaximum
        else { return }

        sidebarItem.maximumThickness = sidebarMaximum
        inspectorItem.maximumThickness = inspectorMaximum
        let message = "Shell pane limits: split=\(Int(splitWidth)) "
            + "pageMin=\(Int(self.layout.minContentWidth)) "
            + "sidebar=[\(Int(sidebarItem.minimumThickness)),\(Int(sidebarMaximum))] "
            + "inspector=[\(Int(inspectorItem.minimumThickness)),\(Int(inspectorMaximum))] "
            + "columnOpen=\(columnOpen) panes=\(Int(sidebarWidth))/\(Int(inspectorWidth))"
        self.logger.debug("\(message, privacy: .public)")
    }

    /// Keeps the window's own minimum at what the panes that are open need.
    ///
    /// `WindowShellLayout.minimumWindowWidth(tracksColumn:)` is the one statement of it — the panes'
    /// minimums plus the dividers, never below the width the app's owner stated — and `MainWindow` states
    /// the same rule on the content it hands the shell, so the two agree instead of fighting. The window
    /// can therefore never be dragged to a width at which a pane has to give up its minimum.
    private func applyWindowMinimumSize() {
        guard let window = self.view.window else { return }

        let minimum = self.layout.minimumWindowWidth(
            tracksColumn: self.inspectorItem?.isCollapsed == false
        )
        guard window.contentMinSize.width != minimum else { return }

        window.contentMinSize = NSSize(
            width: minimum,
            height: window.contentMinSize.height
        )
        let message = "Shell minimum window width: \(Int(minimum)) "
            + "(columnOpen=\(self.inspectorItem?.isCollapsed == false))"
        self.logger.info("\(message, privacy: .public)")
        // A minimum the window is already below — a restored frame, or one from a build with different
        // arithmetic — is corrected here rather than left to the next resize.
        self.growWindowToMinimumIfNeeded()
    }

    /// Reports a collapse the reader performed, so the app's page state follows the pane.
    private func inspectorCollapseDidChange(_ collapsed: Bool) {
        let source = self.isApplyingState ? "app" : "reader"
        self.logger.debug("Now Playing column collapsed=\(collapsed) source=\(source)")
        guard !self.isApplyingState else { return }
        self.onInspectorCollapsedChange?(collapsed)
    }

    // MARK: - Diagnostics

    /// Writes the window's state on every meaningful resize, which is where a collapsing column is
    /// visible.
    ///
    /// `viewDidLayout` runs on every pass of a live resize, so this logs only when the split view's
    /// width actually moved, when the column's collapsed state changed, or when the drag ended — the
    /// shape of the evidence without the flood.
    private func logLayoutIfNeeded() {
        let splitWidth = self.splitView.bounds.width
        guard splitWidth > 0 else { return }

        let inspectorCollapsed = self.inspectorItem?.isCollapsed ?? true
        let isLiveResize = self.splitView.inLiveResize

        let widthChanged = !(self.lastLoggedSplitWidth.isFinite
            && abs(self.lastLoggedSplitWidth - splitWidth) < 4)
        let collapseChanged = !self.hasLoggedLayout
            || inspectorCollapsed != self.lastLoggedInspectorCollapsed
        let resizeEnded = self.wasInLiveResize && !isLiveResize
        guard widthChanged || collapseChanged || resizeEnded else { return }

        self.lastLoggedSplitWidth = splitWidth
        self.lastLoggedInspectorCollapsed = inspectorCollapsed
        self.hasLoggedLayout = true
        self.wasInLiveResize = isLiveResize

        let panes = self.splitView.arrangedSubviews
        let sidebarWidth = panes.first?.frame.width ?? 0
        let inspectorWidth = panes.count > 2 ? panes[2].frame.width : 0

        let message = "Shell layout: split=\(Int(splitWidth)) "
            + "window=\(Int(self.view.window?.frame.width ?? 0)) "
            + "sidebar=\(Int(sidebarWidth)) inspector=\(Int(inspectorWidth)) "
            + "sidebarCollapsed=\(self.sidebarItem?.isCollapsed ?? false) "
            + "inspectorCollapsed=\(inspectorCollapsed) "
            + "liveResize=\(isLiveResize) resizeEnded=\(resizeEnded) "
            + "minWidth=\(Int(self.view.window?.contentMinSize.width ?? 0))"
        self.logger.debug("\(message, privacy: .public)")
    }

    /// Reports what the navigation sidebar's surface actually is, once per launch.
    ///
    /// A wrongly grey sidebar is a compositing question: which `NSVisualEffectView` is in the pane,
    /// what material it asks for, whether it blends behind the window or within it, and whether the
    /// window behind it is transparent at all. None of that is in the source, because AppKit's own
    /// sidebar item installs a background view the app never creates — so this reports the tree rather
    /// than leaving the answer to inspection by eye.
    private func logSidebarSurfaceIfNeeded() {
        guard !self.hasLoggedSidebarSurface, let window = self.view.window else { return }
        self.sidebarSurfaceProbeAttempts += 1

        let sidebarView = self.sidebarController.view
        var effectViews: [NSVisualEffectView] = []
        // From the *theme frame*, not the content view: the titlebar and the toolbar are the window's,
        // not the content's, so a glass background over the top of the sidebar is a sibling of the whole
        // content view and is invisible to a walk that starts inside it.
        if let themeRoot = window.contentView?.superview ?? window.contentView {
            Self.collectEffectViews(in: themeRoot, into: &effectViews)
        }

        // The sidebar's SwiftUI builds its view representables an arbitrary number of layout passes
        // after the shell is first laid out — the window is created, the shell is attached, and only
        // then does the hosting view reach the point of making `SidebarMaterialPane`'s effect view.
        // An empty tree on the first pass is therefore the probe asking too early, not an answer, so
        // an empty result keeps trying for a bounded number of passes before it is reported as one.
        guard !effectViews.isEmpty || self.sidebarSurfaceProbeAttempts >= 30 else { return }
        self.hasLoggedSidebarSurface = true

        self.logSidebarSurface(phase: "early", sidebarView: sidebarView, effectViews: effectViews, window: window)

        // The early pass is not the whole answer. On the pass that first finds the material, the `List`
        // may have built one row and no table at all — and the rows are exactly the region a grey
        // sidebar report is about — so the tree is read once more after the list has settled.
        self.sidebarSurfaceSettledProbe = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(2500))
            guard let self, !Task.isCancelled else { return }
            self.logSidebarSurface(phase: "settled")
        }
    }

    /// Reports the sidebar's compositing: the material, and whatever is drawn over it.
    ///
    /// `phase` separates the tree read the moment the shell appears from the one read once the list has
    /// populated, because only the second is a statement about the rows the reader is looking at.
    private func logSidebarSurface(
        phase: String,
        sidebarView: NSView? = nil,
        effectViews: [NSVisualEffectView]? = nil,
        window: NSWindow? = nil
    ) {
        guard let window = window ?? self.view.window else { return }
        let sidebarView = sidebarView ?? self.sidebarController.view
        let contentView = window.contentView

        var effectViews = effectViews ?? []
        if effectViews.isEmpty {
            if let themeRoot = contentView?.superview ?? contentView {
                Self.collectEffectViews(in: themeRoot, into: &effectViews)
            }
        }

        let chrome = "phase=\(phase) probe=\(self.sidebarSurfaceProbeAttempts) "
            + "windowOpaque=\(window.isOpaque) "
            + "backgroundAlpha=\(String(format: "%.2f", window.backgroundColor.alphaComponent)) "
            + "fullSizeContent=\(window.styleMask.contains(.fullSizeContentView)) "
            + "titlebarTransparent=\(window.titlebarAppearsTransparent) "
            + "titlebarSeparator=\(window.titlebarSeparatorStyle.rawValue) "
            + "key=\(window.isKeyWindow) "
            + "appearance=\(window.effectiveAppearance.name.rawValue)"

        // The sidebar's own region in window coordinates, so an effect view's frame can be read against
        // the column it may be covering.
        let sidebarInWindow = sidebarView.convert(sidebarView.bounds, to: nil)

        var surface = "sidebarPane=\(type(of: sidebarView)) effectViews=\(effectViews.count) "
            + "sidebarFrame=\(Int(sidebarView.frame.width))x\(Int(sidebarView.frame.height)) "
            + "sidebarInWindow=\(Int(sidebarInWindow.minX)),\(Int(sidebarInWindow.minY)) "
            + "\(Int(sidebarInWindow.width))x\(Int(sidebarInWindow.height))"
        for (index, effectView) in effectViews.enumerated() {
            surface += " | effect#\(index) \(Self.describe(effectView))"
            surface += " inContent=\(contentView.map { Self.isAncestor($0, of: effectView) } ?? false)"
            surface += " wrapsSidebar=\(Self.isAncestor(effectView, of: sidebarView))"
            surface += " insideSidebar=\(Self.isAncestor(sidebarView, of: effectView))"
        }

        let message = "Sidebar surface: \(chrome) \(surface)"
        self.logger.info("\(message, privacy: .public)")

        // An effect view is not the only way to paint over the sidebar's material: an opaque
        // `backgroundColor` on a scroll view, clip view or table — or a layer background behind any of
        // them — covers it just as well, and none of those is visible in the effect-view list above.
        //
        // Reported as its own line, and so is the row report below: OSLog truncates a long message in
        // the *middle* (the reason the effect-view list ends in `\u2026`), which is exactly where the
        // answer to "why is this grey" would have been.
        for background in Self.opaqueBackgrounds(in: sidebarView) {
            let paint = "Sidebar surface paint: phase=\(phase) \(background)"
            self.logger.info("\(paint, privacy: .public)")
        }

        // The rows themselves, because "the sidebar's text is grey" is a statement about the table's
        // *rows*: `NSColor.labelColor` resolves to its low-contrast variant whenever the row view is
        // unemphasized, and that resolution happens inside AppKit, not in any view the app writes.
        let rows = "Sidebar surface rows: phase=\(phase) \(Self.sourceListReport(in: sidebarView))"
        self.logger.info("\(rows, privacy: .public)")

        // And what the sidebar actually *renders*: the resolved colours above are the mechanism, this is
        // the outcome.
        if phase == "settled" {
            self.logSidebarInk(phase: phase)
        }
    }

    /// The ink the sidebar's rows actually draw: how dark their darkest pixel is, and how red they are.
    ///
    /// The captured bitmap is the *layer tree* (`CALayer.render(in:)`), not `cacheDisplay`: the latter
    /// draws only what a view paints in `draw(_:)`, and SwiftUI draws into layers, so it came back with
    /// the rows' text missing entirely — a "darkest pixel" of 0.92 on a row whose label is black, which
    /// would have been read as "the text is faint" when it only meant "the capture is empty".
    ///
    /// The numbers are worth having because a label's contrast is exactly this: a full-contrast label
    /// measures ≈0.00, the dimmed rendering a `NavigationLink` with no navigation container gives its
    /// label measures ≈0.50, and the icons should show a red channel well above their green and blue.
    private func logSidebarInk(phase: String) {
        let pane = self.sidebarController.view
        let scale: CGFloat = 2
        let width = Int(pane.bounds.width * scale)
        let height = Int(pane.bounds.height * scale)
        guard width > 1, height > 1, let layer = pane.layer else { return }

        var data = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.scaleBy(x: scale, y: scale)
            layer.render(in: context)
            return true
        }
        guard rendered else { return }

        // A geometry-flipped layer (what AppKit gives a flipped view) counts its rows from the top, an
        // ordinary one from the bottom.
        let flippedLayer = layer.isGeometryFlipped

        // Whether the capture holds anything at all, and what the darkest ink in it is: a row report of
        // "no pixels" means the capture is empty, not that the rows are blank.
        var opaque = 0
        var darkestAnywhere = 1.0
        var darkestRow = -1
        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = (y * width + x) * 4
                let alpha = Double(data[index + 3]) / 255
                guard alpha > 0.02 else { continue }
                opaque += 1
                let red = Double(data[index + 2]) / 255 / alpha
                let green = Double(data[index + 1]) / 255 / alpha
                let blue = Double(data[index]) / 255 / alpha
                let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                if luminance < darkestAnywhere {
                    darkestAnywhere = luminance
                    darkestRow = y
                }
            }
        }
        let whole = "Sidebar ink: phase=\(phase) opaque=\(opaque)/\(width * height) "
            + "darkest=\(Self.format(darkestAnywhere)) atRow=\(darkestRow) "
            + "flippedLayer=\(flippedLayer) paneFlipped=\(pane.isFlipped)"
        self.logger.info("\(whole, privacy: .public)")

        // Bands rather than row rects: the layer counts from the pane's top (`flippedLayer` is true), so
        // the navigation rows are the bitmap's first few hundred rows and the profile section — which has
        // always drawn at full contrast, and is therefore the control — is at the bottom.
        let navigation = Self.ink(
            data: data, width: width, scale: scale, height: height,
            fromTop: 0, toTop: min(height, Int(260 * scale))
        )
        let profile = Self.ink(
            data: data, width: width, scale: scale, height: height,
            fromTop: max(0, height - Int(120 * scale)), toTop: height
        )
        let message = "Sidebar ink bands: phase=\(phase) rows="
            + "[ink=\(Self.format(navigation.darkest)) red=\(Self.format(navigation.redness)) "
            + "px=\(navigation.pixels)] profile="
            + "[ink=\(Self.format(profile.darkest)) red=\(Self.format(profile.redness)) "
            + "px=\(profile.pixels)]"
        self.logger.info("\(message, privacy: .public)")
    }

    /// The darkest pixel and the strongest red in a horizontal band of the captured bitmap.
    private static func ink(
        data: [UInt8],
        width: Int,
        scale: CGFloat,
        height: Int,
        fromTop: Int,
        toTop: Int
    ) -> (darkest: Double, redness: Double, pixels: Int) {
        var darkest = 1.0
        var redness = -1.0
        var pixels = 0
        for y in max(0, fromTop) ..< min(height, toTop) {
            for x in 0 ..< width {
                let index = (y * width + x) * 4
                let alpha = Double(data[index + 3]) / 255
                guard alpha > 0.02 else { continue }
                // Premultiplied: undo the alpha so a faint label is not read as a dark one.
                let red = Double(data[index + 2]) / 255 / alpha
                let green = Double(data[index + 1]) / 255 / alpha
                let blue = Double(data[index]) / 255 / alpha
                pixels += 1
                darkest = min(darkest, 0.2126 * red + 0.7152 * green + 0.0722 * blue)
                redness = max(redness, red - max(green, blue))
            }
        }
        return (darkest, redness, pixels)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }



    /// Views inside the sidebar that paint an opaque background of their own, with the colour they use.
    ///
    /// This is the other half of "the sidebar looks grey": the material can be perfectly configured and
    /// still be invisible, because something opaque is drawn on top of it.
    private static func opaqueBackgrounds(in root: NSView) -> [String] {
        var found: [String] = []
        var stack: [NSView] = [root]

        while let view = stack.popLast() {
            let name = String(describing: type(of: view))
            let frame = "\(Int(view.frame.width))x\(Int(view.frame.height))"

            if let scrollView = view as? NSScrollView {
                found.append("scrollView \(name) \(frame) drawsBackground=\(scrollView.drawsBackground) "
                    + "color=\(Self.describe(scrollView.backgroundColor))")
            } else if let clipView = view as? NSClipView {
                found.append("clipView \(frame) draws=\(clipView.drawsBackground) "
                    + "color=\(Self.describe(clipView.backgroundColor))")
            } else if let table = view as? NSTableView {
                found.append("table \(frame) color=\(Self.describe(table.backgroundColor)) "
                    + "alternating=\(table.usesAlternatingRowBackgroundColors)")
            } else if view.wantsLayer, let layerColor = view.layer?.backgroundColor,
                      let color = NSColor(cgColor: layerColor), color.alphaComponent > 0.01
            {
                found.append("layer \(name) \(frame) color=\(Self.describe(color))")
            }

            stack.append(contentsOf: view.subviews)
        }

        return found
    }

    /// What the sidebar's `List` actually built: the table, its first row, and the colours its text is
    /// drawing with.
    ///
    /// A row's label is not the colour the SwiftUI source states. It is whatever AppKit resolves
    /// `labelColor` to for that row view — and an unemphasized row view draws the washed-out variant,
    /// which is exactly the grey a reader reports. None of that appears in the app's source, so it is
    /// reported from the tree.
    private static func sourceListReport(in root: NSView) -> String {
        var table: NSTableView?
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let candidate = view as? NSTableView {
                table = candidate
                break
            }
            stack.append(contentsOf: view.subviews)
        }
        guard let table else { return "sourceList table=nil" }

        var report = "sourceList style=\(table.style.rawValue) rows=\(table.numberOfRows)"

        if let row = (0 ..< table.numberOfRows)
            .compactMap({ table.rowView(atRow: $0, makeIfNecessary: false) })
            .first
        {
            report += " rowEmphasized=\(row.isEmphasized) rowSelected=\(row.isSelected) "
                + "rowAppearance=\(row.effectiveAppearance.name.rawValue)"
            report += " rowTexts=\(self.textFieldColors(in: row))"
        }

        // The hosting view is what draws the SwiftUI the reader sees, so the appearance *it* resolves
        // against is the other half of the answer — and the resolved `labelColor` is the whole answer:
        // the vibrant appearances resolve it to a lower-alpha colour (black @ 0.70 under `VibrantLight`
        // against 0.85 under `Aqua`), which over a light sidebar material *is* the grey label.
        if let host = Self.descendants(of: root).first(where: { $0 is NSHostingView<AnyView> }) {
            report += " hostAppearance=\(host.effectiveAppearance.name.rawValue)"
            host.effectiveAppearance.performAsCurrentDrawingAppearance {
                report += " hostLabelColor=\(Self.describe(NSColor.labelColor))"
            }
            // Which ancestor is responsible, since the answer is *not* the app's own material view.
            report += " vibrantAncestor=\(Self.explicitVibrantAncestor(above: host))"
        }

        return report
    }

    /// The first ancestor that states a vibrant appearance *itself*.
    ///
    /// `effectiveAppearance` says what a view resolves against; `appearance` says who asked for it. The
    /// difference is the whole question when the sidebar's colours are wrong: the app's own material is
    /// `VibrantLight` only for its subtree, but the pane came back vibrant too, which means something
    /// outside the app's representable set it.
    private static func explicitVibrantAncestor(above view: NSView) -> String {
        var current: NSView? = view
        while let candidate = current {
            switch candidate.appearance?.name {
            case .vibrantLight, .vibrantDark:
                return String(describing: type(of: candidate))
            default:
                break
            }
            current = candidate.superview
        }
        return "none"
    }

    private static func descendants(of root: NSView) -> [NSView] {
        var result: [NSView] = [root]
        for subview in root.subviews {
            result.append(contentsOf: self.descendants(of: subview))
        }
        return result
    }

    /// The text colours of the labels inside a row, with the appearance each one resolved against.
    private static func textFieldColors(in root: NSView) -> String {
        var colors: [String] = []
        for view in self.descendants(of: root) {
            guard let textField = view as? NSTextField else { continue }
            colors.append(
                "\(Self.describe(textField.textColor))@\(textField.effectiveAppearance.name.rawValue)"
            )
            if colors.count >= 3 { break }
        }
        return colors.isEmpty ? "none" : colors.joined(separator: ",")
    }

    private static func describe(_ color: NSColor?) -> String {
        guard let color else { return "nil" }
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return String(
            format: "srgb(%.2f,%.2f,%.2f,a=%.2f)",
            rgb.redComponent,
            rgb.greenComponent,
            rgb.blueComponent,
            rgb.alphaComponent
        )
    }

    /// One effect view, named by both its Swift case and its raw value, with the view it hangs under.
    ///
    /// The superview is the identifying fact: an effect view whose superview is the scroll view is the
    /// `List`'s own sidebar material, while one wrapping the sidebar's hosting view is `SidebarMaterialPane`.
    private static func describe(_ effectView: NSVisualEffectView) -> String {
        let blending = switch effectView.blendingMode {
        case .behindWindow: "behindWindow"
        case .withinWindow: "withinWindow"
        default: "blending#\(effectView.blendingMode.rawValue)"
        }
        let state = switch effectView.state {
        case .followsWindowActiveState: "followsWindowActiveState"
        case .active: "active"
        case .inactive: "inactive"
        default: "state#\(effectView.state.rawValue)"
        }
        let superview = effectView.superview.map { String(describing: type(of: $0)) } ?? "nil"
        return "material=\(String(describing: effectView.material))/\(effectView.material.rawValue) "
            + "isSidebarMaterial=\(effectView.material == .sidebar) "
            + "blending=\(blending) state=\(state) "
            + "alpha=\(String(format: "%.2f", effectView.alphaValue)) "
            + "emphasized=\(effectView.isEmphasized) "
            + "hidden=\(effectView.isHidden) superview=\(superview) "
            + "frame=\(Int(effectView.frame.width))x\(Int(effectView.frame.height)) "
            + "inWindow=\(Int(Self.frameInWindow(effectView).origin.x)),\(Int(Self.frameInWindow(effectView).origin.y)) "
            + "\(Int(Self.frameInWindow(effectView).width))x\(Int(Self.frameInWindow(effectView).height))"
    }

    /// The same view's frame in window coordinates, independent of what it hangs under.
    private static func frameInWindow(_ view: NSView) -> NSRect {
        view.convert(view.bounds, to: nil)
    }

    private static func collectEffectViews(in root: NSView, into result: inout [NSVisualEffectView]) {
        if let effectView = root as? NSVisualEffectView {
            result.append(effectView)
        }
        for subview in root.subviews {
            self.collectEffectViews(in: subview, into: &result)
        }
    }

    private static func isAncestor(_ ancestor: NSView, of view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate === ancestor { return true }
            current = candidate.superview
        }
        return false
    }

    /// Places the Now Playing divider at the width the app opens it at, once.
    ///
    /// The inspector item's factory width is the standard 270pt, and the app's own width is 380 — so
    /// without this the column would open narrower than the app asks for. It runs once ever: after that
    /// AppKit's autosave restores whatever the reader dragged it to, and touching the divider here would
    /// undo their choice.
    private func seedDividerIfNeeded() {
        guard !self.hasSeededDivider,
              self.state.showsInspector,
              let inspectorItem = self.inspectorItem,
              !inspectorItem.isCollapsed
        else { return }

        // The inspector has to have been laid out before its divider can be moved: an item that is only
        // now being expanded has no width yet, and `setPosition` on it would be dropped. So this waits for
        // a layout pass it can act on, rather than consuming its one shot on a pass where it cannot.
        let panes = self.splitView.arrangedSubviews
        guard panes.count > 2, panes[2].frame.width > 0 else { return }
        let total = self.splitView.bounds.width
        guard total > 0 else { return }

        self.hasSeededDivider = true
        guard UserDefaults.standard.object(forKey: Self.dividerSeededKey) == nil else { return }
        UserDefaults.standard.set(true, forKey: Self.dividerSeededKey)

        let target = min(
            max(self.state.seedInspectorWidth, self.layout.minInspectorWidth),
            self.layout.maxInspectorWidth
        )
        guard total > target + self.layout.minContentWidth else { return }
        self.splitView.setPosition(
            total - self.splitView.dividerThickness - target,
            ofDividerAt: 1
        )
    }

    // MARK: - Toolbar

    /// Keeps the window's chrome in the shape a sidebar-plus-toolbar window has.
    ///
    /// The app's window sets these when it is created (`AppDelegate.installMainWindow`), so this is
    /// normally a no-op — it is re-asserted from the layout pass, and only writes when a value actually
    /// differs, so nothing that takes the window over later can leave the reader's sidebar looking like an
    /// opaque band above a sidebar.
    private func applyWindowChrome() {
        guard let window = self.view.window else { return }
        self.applyTitleVisibility()
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
        }
        if window.titlebarSeparatorStyle != .none {
            // A hairline under the toolbar draws a line across the whole window, including over the
            // navigation sidebar, where the two regions' different materials meet.
            window.titlebarSeparatorStyle = .none
        }
        // The window is a clear sheet, so the sidebar's material has the desktop to blur rather than the
        // window's own background to blend against. Re-asserted here for the same reason as the rest of
        // the chrome: only a value that actually differs is written, and it means nothing that takes the
        // window over later can put an opaque background back behind the sidebar.
        if window.isOpaque {
            window.isOpaque = false
        }
        if window.backgroundColor.alphaComponent != 0 {
            window.backgroundColor = .clear
        }
    }

    /// Gives the page's region its leading slot back while the page has a back control.
    ///
    /// The window's title is drawn as a flexible view at the **leading** edge of the region right of the
    /// sidebar's tracking separator, and AppKit lays every item of that region out after it — so the
    /// page's own items cannot lead their region while the title holds the slot, however they are ordered.
    /// Measured in a reproduction of this window (1240pt, the app's item order, the state the app installs):
    /// with the title visible the back control sat at x=740, immediately left of the Ask AI button and the
    /// page's controls, and with the title hidden the first of them moved to x=224 — the region's own
    /// leading edge. That is the "the back button is with the other controls on the right" report, and the
    /// title is what it costs.
    ///
    /// Hidden only while there is a back control, and put back as soon as the page is a root again: a root
    /// has nothing that has to lead, so the title keeps the slot the way it always has.
    private func applyTitleVisibility() {
        guard let window = self.view.window else { return }
        if self.toolbarItems.canGoBack {
            if window.titleVisibility != .hidden {
                window.titleVisibility = .hidden
                self.logger.debug("Toolbar title hidden: the page has a back control to lead its region")
            }
        } else if window.toolbar?.isVisible != false, window.titleVisibility != .visible {
            // Never un-hide while the toolbar itself is hidden: the fullscreen Now Playing experience
            // hides both, and with the toolbar gone that is not this method's state to restore
            // (`MainWindow.updateWindowTitleVisibility`).
            window.titleVisibility = .visible
        }
    }

    private func installToolbar() {
        guard let window = self.view.window else { return }
        guard !self.toolbarController.ownsToolbar(of: window) else { return }
        guard self.pendingToolbarInstall == nil else { return }

        // Deferred by one main-actor turn: this runs from inside a layout or appearance pass, and a
        // toolbar is not something to reconfigure while AppKit is laying the window out.
        self.pendingToolbarInstall = Task { @MainActor [weak self] in
            self?.pendingToolbarInstall = nil
            guard let self, let window = self.view.window else { return }
            self.logger.debug("\(self.toolbarController.toolbarTakeoverReport(for: window), privacy: .public)")
            self.toolbarController.install(in: window)
            self.observeToolbarTakeover(of: window)
            // Taking the toolbar back also takes the title back, so the one rule about the region's leading
            // slot is re-stated here rather than left to the next layout pass.
            self.applyTitleVisibility()
        }
    }

    /// Re-takes the window's toolbar the moment anything else puts its own there.
    ///
    /// The app's toolbar is not the only thing that wants to be the window's. SwiftUI's window controller
    /// installs its own as soon as a page's navigation content changes — `PlaylistDetailView` states a
    /// `navigationTitle` while the reader opens an album or a playlist — and that toolbar carries a single
    /// item and none of the app's. The window is then left with a titlebar holding no sidebar toggle, no
    /// page controls and no Now Playing toggle until something states the app's toolbar again, which used
    /// to be the next layout or appearance pass: the reader saw the bar's controls vanish for a beat, and
    /// when no such pass followed, not come back at all.
    ///
    /// KVO, because there is no notification for a replaced toolbar and the app has to win a race it
    /// otherwise does not know has started. Rewriting the window's toolbar is deferred to the next
    /// main-actor turn so it does not happen from inside AppKit's own change callback.
    private func observeToolbarTakeover(of window: NSWindow) {
        guard self.toolbarObservation == nil else { return }
        self.toolbarObservation = window.observe(\.toolbar, options: [.new]) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let self, !self.toolbarController.ownsToolbar(of: window) else { return }
                Task { @MainActor [weak self] in
                    guard let self, let window = self.view.window else { return }
                    guard !self.toolbarController.ownsToolbar(of: window) else { return }
                    self.logger.debug(
                        "Toolbar replaced, restoring the app's: \(self.toolbarController.toolbarTakeoverReport(for: window), privacy: .public)"
                    )
                    self.toolbarController.install(in: window)
                    // Taking the toolbar back also takes the title back — the toolbar that replaced it is
                    // SwiftUI's, and the window's title is what it manages (see `applyTitleVisibility`).
                    self.applyTitleVisibility()
                }
            }
        }
    }
}

// MARK: - SidebarMaterialPane

/// The navigation sidebar's surface: AppKit's sidebar material with the sidebar's SwiftUI hosted
/// **inside** it.
///
/// The effect view is what supplies the sidebar's *own* surface: AppKit's `sidebarWithViewController:`
/// item gives the pane the sidebar's behaviour, and this gives it the sidebar's material. The pane ignores
/// the top safe area so the material runs to the window's top edge (the way a macOS sidebar does), while
/// the hosting view inside it is inset by AppKit's safe area.
///
/// ## The sidebar draws in a vibrant appearance, and cannot be talked out of it
///
/// The sidebar's content resolves its colours against a **vibrant** appearance (`VibrantLight` /
/// `VibrantDark`), where the system colours are *not* the full-contrast ones — see the table on
/// `EmphasizedMaterialView`. It is not this material's doing and it cannot be undone from here: hosting
/// the content *beside* the material was tried, and setting an explicit non-vibrant appearance on the
/// content was tried, and the hosting view came back
/// `hostAppearance=NSAppearanceNameVibrantLight hostLabelColor=srgb(0,0,0,a=0.70)` either way — the
/// appearance is applied to the pane from outside this representable. So the sidebar's own text states
/// **literal** colours rather than depending on `.primary` (`Sidebar.rowForeground(for:)`), which no
/// appearance can re-resolve, and the shell's `Sidebar surface rows:` line publishes the appearance and
/// the resolved label colour so this is never a guess again.
///
/// This appearance is *not* what made the rows grey — that was the rows being `NavigationLink`s with no
/// navigation container left to navigate (see `Sidebar.navigationRow(_:)`, measured 0.498 as a link
/// against 0.000 as a tagged row). The two are worth keeping apart: the appearance dims a *dynamic*
/// colour, the link dims the whole row whatever colour it is given. `Sidebar ink:` is the line that
/// measures the rendered result of both.
///
/// ## `.behindWindow`, and why the window has to be clear
///
/// The material blurs what is *behind the window*, not what is behind the view. That is the difference
/// between a macOS sidebar and a grey panel: `.withinWindow` has only the window's own background to
/// composite against, so `.sidebar` renders as a flat grey sheet laid over it — which is what the column
/// looked like. For `.behindWindow` to have the desktop to sample, the window must not be opaque and must
/// not draw a background (`AppDelegate.installMainWindow`); the panes that *are* a surface — the page and
/// the Now Playing column — paint their own opaque backgrounds, so the translucency is the sidebar's
/// alone.
///
/// ## Emphasis, and the rows' contrast
///
/// A sidebar's rows draw their selection through the *emphasis* of the effect views around them:
/// unemphasized, a row's highlight renders in the dimmed, washed-out style. `state =
/// .followsWindowActiveState` does not cover this: it changes how the material itself is drawn, while
/// `isEmphasized` is the separate switch AppKit's own sidebar background flips from the window's key
/// state. A material the app supplies has to flip it too, which is what `EmphasizedMaterialView` does for
/// the material itself and `SidebarBackingStyleConfigurator` does for each row view.
///
/// Emphasis does **not** fix the rows' *text*: a row's label colour is what the vibrant appearance
/// resolves the system colours to, and SwiftUI's content resolves them from the appearance alone — which
/// is why the labels state literal colours instead (`Sidebar.rowForeground(for:)`).
@available(macOS 26.0, *)
struct SidebarMaterialPane<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = EmphasizedMaterialView()
        view.material = .sidebar
        // Behind the window: the material is the column's own surface, blurring the desktop the way
        // Finder's and Mail's sidebars do. The window is non-opaque and draws no background for exactly
        // this (see the type's documentation), and every other pane paints an opaque surface of its own.
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState

        let host = NSHostingView(rootView: AnyView(self.content()))
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context _: Context) {
        for case let host as NSHostingView<AnyView> in view.subviews {
            host.rootView = AnyView(self.content())
        }
    }
}

// MARK: - EmphasizedMaterialView

/// The sidebar's material, with the emphasis AppKit's own sidebar background would have given it and the
/// content's colour resolution put back at full contrast.
///
/// `NSVisualEffectView.isEmphasized` defaults to `false`, and unemphasized vibrancy is the low-contrast
/// rendering — the washed-out selection a non-key window shows. AppKit's `sidebarWithViewController:`
/// background view keeps this in step with the window's key state; a material the app installs itself
/// gets no such treatment (see `SidebarMaterialPane`). This is half of the missing treatment.
///
/// ## The appearances, and what the system colours are worth in each
///
/// The sidebar's content draws in a **vibrant** appearance, and the system colours resolve differently
/// there. Measured on this Mac:
///
/// | appearance     | `NSColor.labelColor` | `secondaryLabelColor` |
/// |----------------|----------------------|-----------------------|
/// | `Aqua`         | black @ **0.85**     | black @ 0.50          |
/// | `VibrantLight` | black @ **0.70**     | vibrant (opaque)      |
/// | `DarkAqua`     | white @ 0.85         | white @ 0.55          |
/// | `VibrantDark`  | white @ 0.90         | vibrant (opaque)      |
///
/// 0.70 of a black label over a light sidebar is a dimmer label than the system draws, and `.primary`
/// cannot escape it because `.primary` *is* `labelColor` — which is why the sidebar's own text names
/// literal colours (`Sidebar.rowForeground(for:)`). It is a second-order effect next to the row's own
/// rendering, though: a `NavigationLink` with no navigation container dims its whole label to ≈0.50
/// regardless of colour, which is what a grey sidebar actually turned out to be.
///
/// AppKit's own sidebar rows are its own cells, which the row view's emphasis compensates for; SwiftUI
/// content resolves its colours from the appearance alone. The rows' emphasis is still kept in step, by
/// `SidebarBackingStyleConfigurator`, because that is what the row's own selection highlight draws with.
@available(macOS 26.0, *)
@MainActor
private final class EmphasizedMaterialView: NSVisualEffectView {
    private var keyObservers: [any NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-registered rather than kept: the coordinator's object changes with the window.
        self.removeKeyObservers()
        self.updateEmphasis()

        guard let window = self.window else { return }
        let center = NotificationCenter.default
        self.keyObservers = [
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateEmphasis() }
            },
            center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateEmphasis() }
            },
        ]
    }

    /// Emphasis follows the window, so an inactive window's sidebar still reads as inactive.
    private func updateEmphasis() {
        self.isEmphasized = self.window?.isKeyWindow ?? false
    }

    private func removeKeyObservers() {
        for observer in self.keyObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        self.keyObservers = []
    }
}
