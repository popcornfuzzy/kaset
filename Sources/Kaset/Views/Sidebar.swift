import SwiftUI

/// Sidebar navigation for the main window, styled like Apple Music.
@available(macOS 26.0, *)
struct Sidebar: View {
    @Binding var selection: SidebarSelection?
    @Environment(LibraryViewModel.self) private var libraryViewModel: LibraryViewModel?
    @Environment(\.colorScheme) private var colorScheme
    @State private var isPlaylistsExpanded = false

    private var sidebarLibraryPlaylists: [Playlist] {
        guard let libraryViewModel else { return [] }
        return libraryViewModel.playlists.filter(Self.shouldShowLibrarySubplaylist)
    }

    private static func shouldShowLibrarySubplaylist(_ playlist: Playlist) -> Bool {
        let normalizedId = normalizedPlaylistId(playlist.id)
        if normalizedId == "LM" {
            return false
        }

        let normalizedTitle = playlist.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if normalizedTitle == "liked music" || normalizedTitle == "liked musik" || normalizedTitle == "new episodes" {
            return false
        }

        return true
    }

    private static func normalizedPlaylistId(_ playlistId: String) -> String {
        if playlistId.hasPrefix("VL") {
            return String(playlistId.dropFirst(2))
        }
        return playlistId
    }

    var body: some View {
        VStack(spacing: 0) {
            // A plain `Group`, not a `GlassEffectContainer`: nothing in the list uses a glass effect, so
            // the container only wrapped the sidebar's content in another compositing layer.
            Group {
                List(selection: self.$selection) {
                    // Main navigation
                    Section {
                        self.navigationRow(.search)
                            .accessibilityIdentifier(AccessibilityID.Sidebar.searchItem)

                        self.navigationRow(.home)
                            .accessibilityIdentifier(AccessibilityID.Sidebar.homeItem)
                    }

                    // Discover section
                    Section(String(localized: "Discover")) {
                        self.navigationRow(.explore)
                            .accessibilityIdentifier(AccessibilityID.Sidebar.exploreItem)

                        self.navigationRow(.charts)
                            .accessibilityIdentifier(AccessibilityID.Sidebar.chartsItem)

                        self.navigationRow(.moodsAndGenres)
                            .accessibilityIdentifier(AccessibilityID.Sidebar.moodsAndGenresItem)

                        self.navigationRow(.newReleases)
                            .accessibilityIdentifier(AccessibilityID.Sidebar.newReleasesItem)

                        self.navigationRow(.podcasts)
                            .accessibilityIdentifier(AccessibilityID.Sidebar.podcastsItem)
                    }

                    // Collection section
                    Section(String(localized: "Collection")) {
                        self.navigationRow(.library)
                            .padding(.leading, 20)
                            .overlay(alignment: .leading) {
                                Button {
                                    self.isPlaylistsExpanded.toggle()
                                } label: {
                                    Image(systemName: self.isPlaylistsExpanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .frame(width: 28, height: 28)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 2)
                                .accessibilityIdentifier(AccessibilityID.Sidebar.libraryDisclosure)
                            }
                            .accessibilityIdentifier(AccessibilityID.Sidebar.libraryItem)

                        if self.isPlaylistsExpanded {
                            ForEach(self.sidebarLibraryPlaylists) { playlist in
                                HStack(spacing: 8) {
                                    self.playlistThumbnail(for: playlist)
                                    Text(playlist.title)
                                        .foregroundStyle(self.rowForeground(for: .playlist(playlist.id)))
                                }
                                .padding(.leading, 20)
                                .tag(SidebarSelection.playlist(playlist.id))
                                .accessibilityIdentifier(AccessibilityID.Sidebar.playlistItem(playlist.id))
                            }
                        }

                        self.navigationRow(.likedMusic)
                            .accessibilityIdentifier(AccessibilityID.Sidebar.likedMusicItem)

                        self.navigationRow(.history)
                            .accessibilityIdentifier(AccessibilityID.Sidebar.historyItem)
                    }
                }
                .listStyle(.sidebar)
                // The sidebar's surface is the pane's `NSVisualEffectView` (`SidebarMaterialPane`), so the
                // list must not paint a background of its own: an opaque list background sits *on top of*
                // the material, which is what left the column looking like a flat grey sheet no matter
                // what stood behind it — and what stopped the sidebar's own vibrancy from compositing.
                .scrollContentBackground(.hidden)
                .background(SidebarBackingStyleConfigurator())
                .clipShape(Rectangle())
                .animation(nil, value: self.selection)
                .accessibilityIdentifier(AccessibilityID.Sidebar.container)
                .onChange(of: self.selection) { _, newValue in
                    if newValue != nil {
                        HapticService.navigation()
                    }
                }
            }

            Divider()
                .opacity(0.3)

            // Profile section at bottom
            SidebarProfileView()
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
    }

    /// A navigation row: the label in full contrast, the icon in the app's red, and the row itself
    /// **tagged** with what selecting it means.
    ///
    /// Tagged, not a `NavigationLink`. The rows used to be links because the sidebar lived inside a
    /// `NavigationSplitView`; the AppKit window shell replaced that split view, and a `NavigationLink`
    /// whose value has no navigation container to navigate renders its label in the **inactive** style.
    /// Measured in a reproduction of exactly this arrangement: the row's darkest rendered pixel came back
    /// 0.498 grey against 0.000 for the same row as a tagged one, the material made no difference, and no
    /// `foregroundStyle` on the link's label could change it — a literal `Color.black` included. That is
    /// the grey the reader kept reporting, and it is why stating colours never helped.
    ///
    /// Nothing is lost by dropping the link: the page the sidebar opens has always been driven by this
    /// list's own `selection` binding (`MainWindow.detailView(for:)` reads it), which is what the links'
    /// `value` was feeding anyway.
    private func navigationRow(_ item: NavigationItem) -> some View {
        Label {
            Text(item.displayName)
                .foregroundStyle(self.rowForeground(for: .navigation(item)))
        } icon: {
            Image(systemName: item.icon)
                .foregroundStyle(self.iconForeground(for: .navigation(item)))
        }
        .tag(SidebarSelection.navigation(item))
    }

    /// The sidebar's glyphs carry the app's own colour — Kaset red — while the labels stay neutral, the
    /// way Apple Music tints its sidebar icons and keeps its labels black.
    ///
    /// A *selected* row's glyph goes white with its label: the selection tint is a filled pill, and a red
    /// glyph on it reads as a second, competing colour — Apple Music whitens both halves of the row.
    private func iconForeground(for value: SidebarSelection) -> AnyShapeStyle {
        self.selection == value
            ? AnyShapeStyle(.white)
            : AnyShapeStyle(PackageResourceLookup.brandAccent)
    }

    /// A row's label, in a colour no appearance can re-resolve.
    ///
    /// A literal, rather than `.primary`, because the sidebar draws in a **vibrant** appearance: `.primary`
    /// *is* `NSColor.labelColor`, and the vibrant appearances resolve it to a lower-alpha colour — black @
    /// 0.70 under `VibrantLight` against 0.85 under `Aqua` (measured; the table is on
    /// `EmphasizedMaterialView`). A literal colour is not resolved that way. White on the selection tint,
    /// which is what the system draws a selected sidebar row with, and the label colour of the scheme
    /// otherwise.
    private func rowForeground(for value: SidebarSelection) -> AnyShapeStyle {
        if self.selection == value {
            return AnyShapeStyle(.white)
        }
        return AnyShapeStyle(self.colorScheme == .dark ? Color.white : Color.black)
    }


    @ViewBuilder
    private func playlistThumbnail(for playlist: Playlist) -> some View {
        if let thumbnailURL = playlist.thumbnailURL?.highQualityThumbnailURL ?? playlist.thumbnailURL {
            CachedAsyncImage(url: thumbnailURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            .frame(width: 16, height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(.quaternary)
                .frame(width: 16, height: 16)
                .overlay {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
        }
    }
}

/// Styles the AppKit views SwiftUI's sidebar `List` builds underneath the SwiftUI source.
///
/// Internal rather than file-private so a test can drive the coordinator directly: the coordinator's
/// window observations are the part that failed silently once (see `Coordinator.observeWindowKeyState`),
/// and nothing SwiftUI does exposes them.
struct SidebarBackingStyleConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = BackingView(frame: .zero)
        view.coordinator = context.coordinator
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView)
    }

    /// The representable's own view, so this knows the moment it has a window.
    ///
    /// The coordinator's work is entirely about the **window's** state — its key state and who holds its
    /// focus — and SwiftUI runs `makeNSView`/`updateNSView` with the view not yet in one. Both hooks ran
    /// while `view.window` was still nil, so the window's notifications and the observation of its first
    /// responder were never installed at all: the rows were stamped once by the retry loop and then nothing
    /// ever restored them. `viewDidMoveToWindow` is the point at which the window exists.
    final class BackingView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let coordinator, self.window != nil else { return }
            coordinator.attach(to: self)
        }
    }

    /// Two things the SwiftUI source cannot state:
    ///
    /// - The list's scrollers are visually heavy against the sidebar's material, so they are made
    ///   overlay-style and translucent.
    /// - **Every row's emphasis.** A source-list row draws its own selection highlight through
    ///   `isEmphasized`, and AppKit's own sidebar keeps that in step with the window's key state. A
    ///   material the app installs itself gets no such treatment: the row views came back
    ///   `rowEmphasized=false` on an **active** window (the `Sidebar surface rows:` diagnostic in
    ///   `WindowShell`), so the selected row's highlight drew in the dimmed style. This keeps it in step
    ///   the way the platform does, including going back to dim when the window is not key.
    @MainActor
    final class Coordinator {
        private weak var anchor: NSView?
        private var windowObservers: [any NSObjectProtocol] = []
        private var settleTask: Task<Void, Never>?
        /// Watches the window's first responder (see `observeFocusChanges`).
        private(set) var focusObservation: NSKeyValueObservation?
        /// Whether this coordinator has found a window and installed what it needs to follow one.
        ///
        /// Read by the tests that guard `BackingView.viewDidMoveToWindow`: the observations used to be
        /// installed from `makeNSView`/`updateNSView`, which SwiftUI runs with the view not yet in a
        /// window — so they were never installed at all.
        var isObservingWindow: Bool {
            self.focusObservation != nil && !self.windowObservers.isEmpty
        }

        /// How many window notifications this coordinator is registered for, so a test can state that
        /// repeated attaches do not leave a second set behind.
        var windowObserverCount: Int {
            self.windowObservers.count
        }
        /// The passes that re-stamp emphasis after a focus change (see `repairEmphasis`).
        private var emphasisRepairTask: Task<Void, Never>?

        func attach(to view: NSView) {
            self.anchor = view
            self.observeWindowKeyState()
            _ = self.restyle()

            // The list's table and its rows are built an arbitrary number of layout passes after this
            // view exists, so one walk can run before there is anything to find. Retried on a short
            // timer until rows are actually styled, then stopped — never a permanent poll.
            guard self.settleTask == nil else { return }
            self.settleTask = Task { @MainActor [weak self] in
                var styled = false
                for _ in 0 ..< 12 where !styled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, !Task.isCancelled else { return }
                    styled = self.restyle()
                }
                self?.settleTask = nil
            }
        }

        @discardableResult
        private func restyle() -> Bool {
            guard let anchor = self.anchor else { return false }
            SidebarBackingStyleConfigurator.configureScrollers(from: anchor)
            return self.applyRowEmphasis()
        }

        /// Whether there are any rows to style, so the retry loop can stop.
        @discardableResult
        private func applyRowEmphasis() -> Bool {
            guard let pane = self.sidebarPane(), let window = pane.window else { return false }
            let emphasized = window.isKeyWindow
            var rowCount = 0

            for view in SidebarBackingStyleConfigurator.descendants(of: pane) {
                if let row = view as? NSTableRowView {
                    rowCount += 1
                    if row.isEmphasized != emphasized {
                        row.isEmphasized = emphasized
                    }
                } else if let effectView = view as? NSVisualEffectView,
                          effectView.superview is NSTableRowView
                {
                    // The selection highlight is its own effect view inside the row, and it has its own
                    // emphasis switch.
                    if effectView.isEmphasized != emphasized {
                        effectView.isEmphasized = emphasized
                    }
                }
            }

            return rowCount > 0
        }

        /// The sidebar pane's own view: the highest ancestor of this view that is still inside the pane.
        ///
        /// The pane is the split view's sidebar item, so the pane's view is the one whose superview is the
        /// `NSSplitView`. Walking from there rather than from the window is what keeps this off every
        /// *other* table in the window — the page's playlists and the queue are source lists too, and their
        /// rows are nobody's sidebar.
        private func sidebarPane() -> NSView? {
            var current: NSView? = self.anchor
            while let view = current {
                if view.superview is NSSplitView {
                    return view
                }
                current = view.superview
            }
            // No pane found (a preview, say) is not a reason to fall back to the window: that would walk
            // every other source list in it.
            return nil
        }

        /// Re-stamps every row's emphasis while the list settles after a focus change.
        ///
        /// The sidebar's *own* rule is the window's key state, and it is applied once when the list is
        /// built. AppKit's is not: the list flips the selected row's emphasis — and with it the highlight's
        /// colour — the moment the list stops being the window's first responder, which a page can cause
        /// without the window ever losing focus. `SearchView` focuses its search field the instant it
        /// appears, and the sidebar row the reader just clicked went with it: measured in the app, the
        /// selected row reported `rowEmph=true effEmph=true` with a red pill before the page appeared and
        /// `rowEmph=false effEmph=false` with a grey one after, on a **key** window.
        ///
        /// So the rule is re-stated after every focus change, on a few short passes: AppKit's own update
        /// happens inside `makeFirstResponder`, and which side of the notification it lands on is not
        /// something the app can see.
        private func repairEmphasis() {
            self.emphasisRepairTask?.cancel()
            self.emphasisRepairTask = Task { @MainActor [weak self] in
                for delay in [0, 40, 120, 260] {
                    if delay > 0 {
                        try? await Task.sleep(for: .milliseconds(delay))
                    }
                    guard let self, !Task.isCancelled else { return }
                    _ = self.applyRowEmphasis()
                }
            }
        }

        /// Watches who holds the window's focus, so `repairEmphasis` can follow it.
        ///
        /// KVO, because there is no notification for a first-responder change — the window's own
        /// key/resign notifications only cover the window leaving or regaining focus as a whole, which is
        /// not what a page taking the search field does.
        private func observeFocusChanges(of window: NSWindow) {
            guard self.focusObservation == nil else { return }
            self.focusObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.repairEmphasis() }
            }
        }

        private func observeWindowKeyState() {
            guard let window = self.anchor?.window else { return }
            self.observeFocusChanges(of: window)
            guard self.windowObservers.isEmpty else { return }

            let center = NotificationCenter.default
            self.windowObservers = [
                center.addObserver(
                    forName: NSWindow.didBecomeKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { _ = self?.applyRowEmphasis() }
                },
                center.addObserver(
                    forName: NSWindow.didResignKeyNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { _ = self?.applyRowEmphasis() }
                },
            ]
        }

    }

    static func descendants(of root: NSView) -> [NSView] {
        var result: [NSView] = [root]
        for subview in root.subviews {
            result.append(contentsOf: self.descendants(of: subview))
        }
        return result
    }

    @MainActor
    private static func configureScrollers(from view: NSView) {
        let candidates = self.findSidebarScrollViews(from: view)
        if !candidates.isEmpty {
            for scrollView in candidates {
                self.applySubtleStyle(on: scrollView)
            }
            return
        }

        // Retry once on the next run loop when the NSView hierarchy has settled.
        Task { @MainActor in
            let candidates = self.findSidebarScrollViews(from: view)
            guard !candidates.isEmpty else { return }
            for scrollView in candidates {
                self.applySubtleStyle(on: scrollView)
            }
        }
    }

    @MainActor
    private static func applySubtleStyle(on scrollView: NSScrollView) {
        // Keep scrolling fully intact, only make scrollers less visually dominant.
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .default
        scrollView.autohidesScrollers = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScroller?.alphaValue = 0.55
    }

    @MainActor
    private static func findSidebarScrollViews(from view: NSView) -> [NSScrollView] {
        var matches: [NSScrollView] = []

        if let directScrollView = self.firstSuperviewScrollView(of: view) {
            matches.append(directScrollView)
        }

        guard let root = view.window?.contentView else {
            return matches
        }

        let markerPoint = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let allScrollViews = self.allDescendantScrollViews(in: root)
        let pointMatches = allScrollViews.filter { scrollView in
            let frameInWindow = scrollView.convert(scrollView.bounds, to: nil)
            return frameInWindow.contains(markerPoint)
        }

        for scrollView in pointMatches where !matches.contains(scrollView) {
            matches.append(scrollView)
        }

        return matches
    }

    @MainActor
    private static func firstSuperviewScrollView(of view: NSView) -> NSScrollView? {
        var currentView: NSView? = view
        while let candidate = currentView {
            if let scrollView = candidate as? NSScrollView {
                return scrollView
            }
            currentView = candidate.superview
        }
        return nil
    }

    @MainActor
    private static func allDescendantScrollViews(in root: NSView) -> [NSScrollView] {
        var results: [NSScrollView] = []

        if let scrollView = root as? NSScrollView {
            results.append(scrollView)
        }

        for subview in root.subviews {
            results.append(contentsOf: self.allDescendantScrollViews(in: subview))
        }

        return results
    }
}

@available(macOS 26.0, *)
#Preview {
    Sidebar(selection: .constant(.navigation(.home)))
        .frame(width: 220)
}
