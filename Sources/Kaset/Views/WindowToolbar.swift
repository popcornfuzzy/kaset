import AppKit
import SwiftUI

// MARK: - NowPlayingSidebarToolbarHeader

/// The Now Playing column's own header: back to the overview, and the name of the page being shown.
///
/// The column's expanded pages used to draw this header inside the column, just below the window's
/// toolbar. That band is the window's chrome, not the column's layout: content cannot be laid out in it,
/// so every page carried a strip of empty column between the toolbar and its first row while the toolbar
/// row itself held nothing but the toggle. Stating the header as a toolbar item puts it where a macOS
/// sidebar keeps its controls — in the band above the column — and lets the page's content begin at the
/// top of the column, with no gap above it.
@available(macOS 26.0, *)
struct NowPlayingSidebarToolbarHeader {
    /// The page's name, drawn beside the back control.
    let title: String
    /// Returns the column to its overview. The column's own page state is the app's, so the action is a
    /// closure rather than a selector.
    let onBack: () -> Void
}

// MARK: - NowPlayingSidebarToolbarHeaderView

/// The column's header as the toolbar draws it: the back chevron and the page's name.
///
/// Deliberately the same shape the header had inside the column — a quiet chevron and a semibold label —
/// so moving it into the toolbar does not change what the reader reads.
@available(macOS 26.0, *)
struct NowPlayingSidebarToolbarHeaderView: View {
    let header: NowPlayingSidebarToolbarHeader

    var body: some View {
        // One control, not a glyph beside a label: the whole capsule is the target, so the name is as
        // clickable as the chevron. `contentShape` inside the label — after the padding — is what makes the
        // item's own inset part of the button rather than dead glass around it.
        Button(action: self.header.onBack) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)

                Text(self.header.title)
                    .font(.system(size: 13, weight: .semibold))
            }
            // The toolbar draws its glass capsule behind the item's *content*, so this inset is what keeps
            // the chevron and the name off the capsule's own edge. The controls that share the toolbar
            // (search field, menus, buttons) carry their own padding; a header that is only a glyph and a
            // label has none of its own, and without this the capsule hugged both.
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Back to Now Playing"))
        .accessibilityLabel(String(localized: "Back to Now Playing"))
        .accessibilityIdentifier(AccessibilityID.NowPlayingSidebar.backButton)
    }
}

// MARK: - WindowToolbarItems

/// What the window's toolbar shows: the app's own items, and whether the regions AppKit owns are in play.
///
/// A value type, so the toolbar can tell "the app's toolbar changed" from "the view was re-evaluated" and
/// rebuild the item list only in the first case.
@available(macOS 26.0, *)
struct WindowToolbarItems {
    /// Whether the Now Playing sidebar is open. Only then is there an inspector divider for the toolbar's
    /// inspector region to track, and only then does the region to its right have anything to hold.
    var tracksColumn: Bool
    /// Whether the Ask AI button is shown. The button requires Apple Intelligence, exactly as the SwiftUI
    /// control it replaces did.
    var showsAI: Bool
    /// Whether the Now Playing toggle lives in the toolbar. It does whenever the column design is on,
    /// open or closed: while the column is closed it is the window's trailing control, and while it is
    /// open it is the trailing control of the toolbar's *inspector* region — the one above the column.
    var showsNowPlayingToggle: Bool
    /// Whether the page on screen has somewhere to go back to (see `PageNavigationModel`). The window's
    /// toolbar is the app's own, so the back control a pushed page needs is the app's to draw.
    var canGoBack: Bool
    /// The page's own controls (search, sort, refresh), or `nil` while the page on screen has none.
    var pageControls: PageToolbarContribution?
    /// The Now Playing column's header, or `nil` while the column is closed or is showing its overview:
    /// the overview *is* the top of the column, so it needs no header of its own.
    var sidebarHeader: NowPlayingSidebarToolbarHeader?
    var onBack: () -> Void
    var onAI: () -> Void

    /// The window's item order.
    ///
    /// The order *is* the mechanism: each tracking separator turns the region before it into one whose
    /// items are laid out against its trailing edge, so the sidebar's toggle and separator come first,
    /// the page's own controls and the AI button share one right-aligned run that ends at the Now Playing
    /// divider — the page's controls therefore stop where the column begins instead of landing on it — and
    /// the inspector's separator comes last, with the Now Playing toggle pushed to the window's trailing
    /// edge behind it.
    ///
    /// The toggle never moves into the column. It used to, and the column carried its own control in its
    /// top-trailing corner so that opening the sidebar looked like the toggle sliding into it — but that
    /// put a small glyph on top of the cover art, in the band the artwork should own, while AppKit's
    /// toolbar item (its own glass chrome, aligned with every other control) already exists. So the
    /// toolbar item stays, in the region that is above the column, and the column's backdrop is left to
    /// the artwork.
    var identifiers: [NSToolbarItem.Identifier] {
        var rightAligned: [NSToolbarItem.Identifier] = []
        if self.showsAI {
            rightAligned.append(WindowToolbarItem.ai)
            // macOS 26 draws one glass capsule behind a *contiguous* run of toolbar items, so two
            // bordered items sitting next to each other are drawn as a single stretched control — which
            // is what made the Ask AI button and the page's own controls read as one wide pill. A fixed
            // space is a real item in the run: it ends the capsule, so each control keeps its own shape.
            if self.pageControls != nil {
                rightAligned.append(.space)
            }
        }
        if self.pageControls != nil {
            rightAligned.append(WindowToolbarItem.pageControls)
        }

        var identifiers: [NSToolbarItem.Identifier] = [.toggleSidebar, .sidebarTrackingSeparator]
        // Immediately after the sidebar's separator, which is the leading edge of the region the sidebar
        // bounds: the back control belongs to the page, and a macOS window puts it first in the page's own
        // run, before anything the page *does*.
        if self.canGoBack {
            identifiers.append(WindowToolbarItem.back)
        }
        // The flexible space is what pushes that run to the region's trailing edge. It is added only when
        // the run is non-empty: with nothing to push it would only widen the gap after the sidebar.
        if !rightAligned.isEmpty {
            identifiers.append(.flexibleSpace)
        }
        identifiers.append(contentsOf: rightAligned)
        // Only while the column is open: with the column closed its divider sits at the window's edge, so
        // the region to the separator's right would be empty and the control that opens the column — which
        // belongs there — would have nowhere to go.
        if self.tracksColumn {
            identifiers.append(.inspectorTrackingSeparator)
            // The column's own header, at the leading edge of the region above the column — where the
            // column begins — so the flexible space that follows pushes only the toggle to the window's
            // trailing edge.
            if self.sidebarHeader != nil {
                identifiers.append(WindowToolbarItem.sidebarHeader)
            }
        }
        if self.showsNowPlayingToggle {
            // A flexible space per region: with the column open the toggle's region is the inspector's,
            // and without one the item would sit against the separator at the *leading* edge of that
            // region — over the column's left edge, in the middle of its titlebar band. With it, the
            // toggle is the window's trailing control, where a macOS window puts an inspector toggle.
            if self.tracksColumn {
                identifiers.append(.flexibleSpace)
            }
            identifiers.append(WindowToolbarItem.nowPlaying)
        }
        return identifiers
    }
}

// MARK: - WindowToolbarItem

/// The identifiers the app itself supplies.
///
/// Standard identifiers (`.toggleSidebar`, `.flexibleSpace` and the two tracking separators) are used
/// as-is, so AppKit draws its own chrome and supplies its own items for them.
///
/// File scope rather than nested in the controller, because the item *order* is `WindowToolbarItems`'
/// — it is what the window states about what it has, and it is covered by tests that need no window.
@available(macOS 26.0, *)
enum WindowToolbarItem {
    /// The page's back control, shown while the page has somewhere to go back to.
    static let back = NSToolbarItem.Identifier("Kaset.toolbar.back")
    static let ai = NSToolbarItem.Identifier("Kaset.toolbar.ai")
    /// The page's own controls, as one hosted item (see `PageToolbarContribution`).
    static let pageControls = NSToolbarItem.Identifier("Kaset.toolbar.page")
    /// The toggle that opens the Now Playing sidebar, shown while it is closed.
    static let nowPlaying = NSToolbarItem.Identifier("Kaset.toolbar.nowPlaying")
    /// The Now Playing column's header (back and page name), shown while one of its pages is open.
    static let sidebarHeader = NSToolbarItem.Identifier("Kaset.toolbar.sidebarHeader")
}

// MARK: - WindowToolbarController

/// The window's toolbar: an `NSToolbar` the app owns, whose delegate this is.
///
/// ## Why the toolbar is AppKit's
///
/// A macOS window has **one** toolbar, and SwiftUI positions a view's `ToolbarItem` against the **window**,
/// not against the view. With a sidebar in the middle of the window there is no placement, spacer or
/// ordering that keeps the page's controls off it — the platform's mechanism is a **tracking separator**,
/// a separator that sits on a split view's divider and moves with it, so the items before it are laid out
/// against the region to its left (that is how Finder and Mail stay clear of the inspector). SwiftUI
/// inserts exactly one tracking separator, for the navigation sidebar, and exposes no
/// `ToolbarItemPlacement` for a second. So the toolbar is AppKit's, and its item list is this app's.
///
/// ## What it does not do
///
/// It does not find, measure or position anything. The separators are AppKit's standard ones —
/// `NSToolbarSidebarTrackingSeparatorItemIdentifier` and
/// `NSToolbarInspectorTrackingSeparatorItemIdentifier`, which "automatically configure themselves to
/// track the divider of the sidebar/inspector if one is discovered". The shell (`WindowShellController`)
/// provides a real `sidebarWithViewController:` item and a real `inspectorWithViewController:` item, which
/// are exactly what gets discovered. The app states only whether it has an open inspector at all.
@available(macOS 26.0, *)
@MainActor
final class WindowToolbarController: NSObject, NSToolbarDelegate {
    static let toolbarIdentifier = NSToolbar.Identifier("Kaset.mainToolbar")

    private var toolbar: NSToolbar?
    /// The hosting view of the page's controls. Held so the page can update them in place: the item is
    /// AppKit's, the content is the page's, and only the latter changes as the reader works.
    private var pageControlsView: NSHostingView<AnyView>?
    /// The hosting view of the Now Playing column's header, held for the same reason: opening a different
    /// page of the column changes the name in the header, not the item it lives in.
    private var sidebarHeaderView: NSHostingView<AnyView>?
    private var items = WindowToolbarItems(
        tracksColumn: false,
        showsAI: false,
        showsNowPlayingToggle: false,
        canGoBack: false,
        pageControls: nil,
        sidebarHeader: nil,
        onBack: {},
        onAI: {}
    )

    /// Records the toolbar's inputs. The item list is rebuilt only if it actually differs.
    func apply(items: WindowToolbarItems, onAI: @escaping () -> Void) {
        self.items = items
        self.pageControlsView?.rootView = items.pageControls?.content ?? AnyView(EmptyView())
        self.sidebarHeaderView?.rootView = Self.sidebarHeaderContent(for: items.sidebarHeader)
        self.refresh()
    }

    /// The column's header, as the hosted view it is drawn by.
    private static func sidebarHeaderContent(for header: NowPlayingSidebarToolbarHeader?) -> AnyView {
        guard let header else { return AnyView(EmptyView()) }
        return AnyView(NowPlayingSidebarToolbarHeaderView(header: header))
    }

    /// Gives the window the app's toolbar, or takes back the one this app already installed.
    ///
    /// ## Why the app's own `NSToolbar`
    ///
    /// The item list has to be the app's *and* the object has to be the app's. Handing SwiftUI's own
    /// toolbar our items does not work: SwiftUI's window controller rewrites that toolbar's item list
    /// from its own content on every constraint pass, so the app's items — the sidebar toggle, the Ask AI
    /// button, the page's search/sort/refresh, the two tracking separators — were wiped a pass after they
    /// were stated, leaving a titlebar with no controls in it at all.
    ///
    /// The cost is a SwiftUI defect: replacing the window's toolbar leaves SwiftUI's window controller
    /// holding key-value observations on a toolbar that is no longer in the window, and its next
    /// `AppKitWindowController.updateToolbarIfNeeded` (which runs from `NSHostingView.updateConstraints`,
    /// i.e. inside a display-cycle constraint pass) then removes an observer it is not registered on —
    /// `-[NSObject removeObserver:forKeyPath:]` raises, and AppKit turns an exception escaping a
    /// constraint pass into `+[NSApplication _crashOnException:]` and a `SIGTRAP`. The window controller
    /// manages a toolbar because the app's SwiftUI content asks it to (the toolbar modifiers on the pages,
    /// and the `NavigationStack`s in the page roots), which is why those requests are being removed from
    /// the app. If the crash returns, the remaining fix is for the app to own the `NSWindow` itself
    /// rather than SwiftUI doing it.
    func install(in window: NSWindow) {
        let toolbar: NSToolbar
        if let existing = window.toolbar, existing.identifier == Self.toolbarIdentifier {
            // A toolbar this app already installed — taken over rather than replaced because
            // `NSToolbar.delegate` is weak: after the shell's controller is recreated, the previous
            // delegate is gone and the window's toolbar would stop being able to build any item.
            toolbar = existing
        } else {
            let created = NSToolbar(identifier: Self.toolbarIdentifier)
            created.allowsUserCustomization = false
            created.displayMode = .iconOnly
            created.autosavesConfiguration = false
            // The item list goes in *before* the toolbar goes into the window.
            //
            // An `NSToolbar` is created with no items, and the window draws whatever is attached: a
            // toolbar put into the window empty leaves the whole titlebar bare — no sidebar toggle, no
            // page controls — until the next pass fills it. That instant is a real one the reader can
            // see, and it is what "the bar on top disappears" looks like. Stating the items first means
            // the toolbar is never seen without them.
            created.delegate = self
            created.itemIdentifiers = self.items.identifiers
            window.toolbar = created
            toolbar = created
        }
        self.toolbar = toolbar
        toolbar.delegate = self
        // A toolbar that arrived with items already in it — the one this app installed a moment ago, or
        // its own — has never created *this* controller's page-controls host, so the item it holds must be
        // re-hosted from the page's own content rather than left showing what the previous one drew.
        self.rehostPageControls(in: toolbar)

        self.refresh()
    }

    /// Re-points the toolbar's hosted items at this controller's current content.
    ///
    /// AppKit keeps the items of a toolbar that is already in a window and only asks its delegate for the
    /// ones it does not have. A toolbar the app re-takes therefore comes with whatever hosted item was
    /// built before, which would otherwise keep drawing the old page's controls for good.
    private func rehostPageControls(in toolbar: NSToolbar) {
        if let item = toolbar.items.first(where: { $0.itemIdentifier == WindowToolbarItem.pageControls }) {
            let host = item.view as? NSHostingView<AnyView> ?? {
                let created = NSHostingView(rootView: self.items.pageControls?.content ?? AnyView(EmptyView()))
                created.sizingOptions = [.intrinsicContentSize]
                item.view = created
                return created
            }()
            host.rootView = self.items.pageControls?.content ?? AnyView(EmptyView())
            self.pageControlsView = host
        }

        if let item = toolbar.items.first(where: { $0.itemIdentifier == WindowToolbarItem.sidebarHeader }) {
            let content = Self.sidebarHeaderContent(for: self.items.sidebarHeader)
            let host = item.view as? NSHostingView<AnyView> ?? {
                let created = NSHostingView(rootView: content)
                created.sizingOptions = [.intrinsicContentSize]
                item.view = created
                return created
            }()
            host.rootView = content
            self.sidebarHeaderView = host
        }
    }

    /// Whether the window's current toolbar is the one this controller installed.
    ///
    /// Object identity, so the shell's per-layout check stays a no-op once the toolbar is in place, and
    /// a recreated shell controller re-installs once instead of on every pass.
    func ownsToolbar(of window: NSWindow) -> Bool {
        guard let toolbar = self.toolbar else { return false }
        return toolbar === window.toolbar
    }

    /// What the window's toolbar is, for the diagnostic a replaced toolbar is reported by.
    ///
    /// "Not ours" has two very different causes — this controller has never installed anything, or
    /// something else has put its own toolbar in the window since — and only the second one is a bug the
    /// app can do anything about.
    func toolbarTakeoverReport(for window: NSWindow) -> String {
        let current = window.toolbar
        let installed = self.toolbar == nil ? "none" : "ours"
        let state: String = if let current {
            current === self.toolbar ? "ours" : "other"
        } else {
            "nil"
        }
        let identifiers = current?.itemIdentifiers.map(\.rawValue).joined(separator: ",") ?? ""
        return "Toolbar takeover: installed=\(installed) window=\(state) "
            + "identifier=\(current?.identifier ?? "nil") items=\(current?.itemIdentifiers.count ?? -1) "
            + "ids=[\(identifiers)]"
    }

    /// Invoked by the toolbar's Now Playing toggle.
    ///
    /// Wired by the shell to its own `NSSplitViewController.toggleInspector(_:)`, so the item's action is
    /// the app's rather than a selector sent down the responder chain, where nothing is guaranteed to be
    /// in the chain to receive it — which is why the button used to do nothing at all when pressed.
    var onToggleNowPlaying: (() -> Void)?

    // MARK: - Item list

    private func refresh() {
        guard let toolbar = self.toolbar else { return }
        // The item list is only *ours* while this controller is the toolbar's delegate: without one,
        // AppKit has no object to ask for the app's own identifiers and the custom items vanish.
        if toolbar.delegate !== self {
            toolbar.delegate = self
        }
        let desired = self.items.identifiers
        guard toolbar.itemIdentifiers != desired else { return }
        toolbar.itemIdentifiers = desired
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        self.items.identifiers
    }

    func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .flexibleSpace,
            .space,
            WindowToolbarItem.back,
            WindowToolbarItem.ai,
            WindowToolbarItem.pageControls,
            .inspectorTrackingSeparator,
            WindowToolbarItem.sidebarHeader,
            WindowToolbarItem.nowPlaying,
        ]
    }

    func toolbar(
        _: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar _: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case WindowToolbarItem.back:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(
                systemSymbolName: "chevron.backward",
                accessibilityDescription: String(localized: "Back")
            )
            item.label = String(localized: "Back")
            item.paletteLabel = String(localized: "Back")
            item.toolTip = String(localized: "Back to the previous page")
            // The app's own target, like the Now Playing toggle: the action pops the page's own navigation
            // stack, which is a closure the page published, not something the responder chain can find.
            item.target = self
            item.action = #selector(self.performBack)
            item.isBordered = true
            return item

        case WindowToolbarItem.ai:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: String(localized: "Ask AI"))
            item.label = String(localized: "Ask AI")
            item.paletteLabel = String(localized: "Ask AI")
            item.toolTip = String(localized: "Ask AI (⌘K)")
            item.target = self
            item.action = #selector(self.performAI)
            // AppKit's own toolbar button chrome, so this matches the system controls beside it rather
            // than being a shape the app draws.
            item.isBordered = true
            return item

        case WindowToolbarItem.pageControls:
            let item = NSToolbarItem(itemIdentifier: identifier)
            // A hosted SwiftUI group rather than AppKit controls built by hand: what belongs here is the
            // page's own search field, sort menu and refresh button, reading the page's own model. Hosting
            // them keeps one implementation of each rather than a second one written against AppKit.
            let host = NSHostingView(rootView: self.items.pageControls?.content ?? AnyView(EmptyView()))
            // The group's SwiftUI size is what the item is sized to.
            host.sizingOptions = [.intrinsicContentSize]
            item.view = host
            self.pageControlsView = host
            return item

        case WindowToolbarItem.sidebarHeader:
            let item = NSToolbarItem(itemIdentifier: identifier)
            // A hosted SwiftUI group rather than AppKit controls built by hand, for the same reason the
            // page's controls are: the header is the column's own view of the app's state, and hosting it
            // keeps one implementation of it (`NowPlayingSidebarToolbarHeaderView`) rather than a second
            // one written against AppKit.
            let host = NSHostingView(rootView: Self.sidebarHeaderContent(for: self.items.sidebarHeader))
            host.sizingOptions = [.intrinsicContentSize]
            item.view = host
            self.sidebarHeaderView = host
            return item

        case WindowToolbarItem.nowPlaying:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(
                systemSymbolName: "sidebar.right",
                accessibilityDescription: String(localized: "Now Playing sidebar")
            )
            item.label = String(localized: "Now Playing sidebar")
            item.paletteLabel = String(localized: "Now Playing sidebar")
            item.toolTip = String(localized: "Show or hide the Now Playing sidebar")
            // The app's own target, not `target = nil`: the action runs the shell's
            // `NSSplitViewController.toggleInspector(_:)` (AppKit's animation and AppKit's clamping) but
            // it is addressed to a known object. A responder-chain action is only delivered when some
            // object in the chain implements it *and* AppKit's validation agrees — the exact combination
            // that left this button visible, enabled-looking, and inert.
            item.target = self
            item.action = #selector(self.toggleNowPlayingSidebar(_:))
            item.isBordered = true
            return item

        default:
            // Standard identifiers (`.toggleSidebar`, `.flexibleSpace` and the two tracking separators)
            // fall through to AppKit, which supplies its own item — including the sidebar toggle's own
            // chrome, its `toggleSidebar:` action on the responder chain, and the separators' tracking of
            // the split view's dividers.
            return nil
        }
    }

    @objc private func performAI() {
        self.items.onAI()
    }

    @objc private func performBack() {
        self.items.onBack()
    }

    @objc private func toggleNowPlayingSidebar(_: Any?) {
        self.onToggleNowPlaying?()
    }
}
