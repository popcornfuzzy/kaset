import SwiftUI

/// Sidebar navigation for the main window, styled like Apple Music.
@available(macOS 26.0, *)
struct Sidebar: View {
    @Binding var selection: SidebarSelection?
    @Environment(LibraryViewModel.self) private var libraryViewModel: LibraryViewModel?
    @State private var isPlaylistsExpanded = false

    /// Namespace for glass effect morphing.
    @Namespace private var sidebarNamespace

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
            GlassEffectContainer(spacing: 0) {
                List(selection: self.$selection) {
                    // Main navigation
                    Section {
                        NavigationLink(value: SidebarSelection.navigation(.search)) {
                            Label(NavigationItem.search.displayName, systemImage: NavigationItem.search.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.searchItem)

                        NavigationLink(value: SidebarSelection.navigation(.home)) {
                            Label(NavigationItem.home.displayName, systemImage: NavigationItem.home.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.homeItem)
                    }

                    // Discover section
                    Section(String(localized: "Discover")) {
                        NavigationLink(value: SidebarSelection.navigation(.explore)) {
                            Label(NavigationItem.explore.displayName, systemImage: NavigationItem.explore.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.exploreItem)

                        NavigationLink(value: SidebarSelection.navigation(.charts)) {
                            Label(NavigationItem.charts.displayName, systemImage: NavigationItem.charts.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.chartsItem)

                        NavigationLink(value: SidebarSelection.navigation(.moodsAndGenres)) {
                            Label(NavigationItem.moodsAndGenres.displayName, systemImage: NavigationItem.moodsAndGenres.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.moodsAndGenresItem)

                        NavigationLink(value: SidebarSelection.navigation(.newReleases)) {
                            Label(NavigationItem.newReleases.displayName, systemImage: NavigationItem.newReleases.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.newReleasesItem)

                        NavigationLink(value: SidebarSelection.navigation(.podcasts)) {
                            Label(NavigationItem.podcasts.displayName, systemImage: NavigationItem.podcasts.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.podcastsItem)
                    }

                    // Collection section
                    Section(String(localized: "Collection")) {
                        NavigationLink(value: SidebarSelection.navigation(.library)) {
                            Label(NavigationItem.library.displayName, systemImage: NavigationItem.library.icon)
                                .padding(.leading, 20)
                        }
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
                            .padding(.leading, 2)
                            .accessibilityIdentifier(AccessibilityID.Sidebar.libraryDisclosure)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.libraryItem)

                        if self.isPlaylistsExpanded {
                            ForEach(self.sidebarLibraryPlaylists) { playlist in
                                NavigationLink(value: SidebarSelection.playlist(playlist.id)) {
                                    HStack(spacing: 8) {
                                        self.playlistThumbnail(for: playlist)
                                        Text(playlist.title)
                                    }
                                    .padding(.leading, 20)
                                }
                                .accessibilityIdentifier(AccessibilityID.Sidebar.playlistItem(playlist.id))
                            }
                        }

                        NavigationLink(value: SidebarSelection.navigation(.likedMusic)) {
                            Label(NavigationItem.likedMusic.displayName, systemImage: NavigationItem.likedMusic.icon)
                        }
                        .accessibilityIdentifier(AccessibilityID.Sidebar.likedMusicItem)
                    }
                }
                .listStyle(.sidebar)
                .background(SidebarScrollBarStyleConfigurator())
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

private struct SidebarScrollBarStyleConfigurator: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        let view = NSView(frame: .zero)
        Self.configureIfPossible(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        Self.configureIfPossible(from: nsView)
    }

    @MainActor
    private static func configureIfPossible(from view: NSView) {
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
