import AppKit
import SwiftUI

// MARK: - MainWindow

/// Main application window with sidebar navigation and player bar.
@available(macOS 26.0, *)
struct MainWindow: View {
    private struct PresentedWhatsNew: Identifiable {
        let whatsNew: WhatsNew
        let requestedVersion: WhatsNew.Version

        var id: String {
            "\(self.requestedVersion.description)::\(self.whatsNew.version.description)"
        }
    }

    private enum Layout {
        static let commandBarTopPadding: CGFloat = 72
        static let miniPlayerDefaultWidth: CGFloat = 320
        static let miniPlayerMinWidth: CGFloat = 220
        static let miniPlayerMaxWidth: CGFloat = 760
        static let miniPlayerDefaultAspectRatio: CGFloat = 16.0 / 9.0
        static let miniPlayerMinAspectRatio: CGFloat = 0.3
        static let miniPlayerMaxAspectRatio: CGFloat = 4.0
        static let miniPlayerResizeEdgeThickness: CGFloat = 24
    }

    private enum MiniPlayerResizeEdge: Hashable {
        case left
        case right
        case top
        case bottom
    }

    @Environment(AuthService.self) private var authService
    @Environment(PlayerService.self) private var playerService
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(AccountService.self) private var accountService
    @Environment(SongLikeStatusManager.self) private var likeStatusManager
    @Environment(\.showCommandBar) private var showCommandBar
    @Environment(\.showWhatsNew) private var showWhatsNew

    /// Binding to navigation selection for keyboard shortcut control from parent.
    @Binding var navigationSelection: SidebarSelection?

    /// Shared API client used by all views and services.
    let client: any YTMusicClientProtocol

    @State private var showLoginSheet = false
    @State private var isCommandBarPresented = false
    @State private var whatsNewToPresent: PresentedWhatsNew?
    @State private var miniPlayerWidth: CGFloat = Layout.miniPlayerDefaultWidth

    // MARK: - Cached ViewModels (persist across tab switches)

    @State private var homeViewModel: HomeViewModel?
    @State private var exploreViewModel: ExploreViewModel?
    @State private var searchViewModel: SearchViewModel?
    @State private var chartsViewModel: ChartsViewModel?
    @State private var moodsAndGenresViewModel: MoodsAndGenresViewModel?
    @State private var newReleasesViewModel: NewReleasesViewModel?
    @State private var podcastsViewModel: PodcastsViewModel?
    @State private var libraryViewModel: LibraryViewModel?
    @State private var historyViewModel: HistoryViewModel?

    /// Column visibility state for NavigationSplitView - persisted to fix restoration from dock.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    init(navigationSelection: Binding<SidebarSelection?>, client: any YTMusicClientProtocol) {
        self._navigationSelection = navigationSelection
        self.client = client
        _homeViewModel = State(initialValue: HomeViewModel(client: client))
        _exploreViewModel = State(initialValue: ExploreViewModel(client: client))
        _searchViewModel = State(initialValue: SearchViewModel(client: client))
        _chartsViewModel = State(initialValue: ChartsViewModel(client: client))
        _moodsAndGenresViewModel = State(initialValue: MoodsAndGenresViewModel(client: client))
        _newReleasesViewModel = State(initialValue: NewReleasesViewModel(client: client))
        _podcastsViewModel = State(initialValue: PodcastsViewModel(client: client))
        _libraryViewModel = State(initialValue: LibraryViewModel(client: client))
        _historyViewModel = State(initialValue: HistoryViewModel(client: client))
    }

    private var likedMusicPlaylist: Playlist {
        Playlist(
            id: "LM",
            title: String(localized: "Liked Music"),
            description: nil,
            thumbnailURL: nil,
            trackCount: nil,
            author: nil
        )
    }

    /// Access to the app delegate for persistent WebView.
    private var appDelegate: AppDelegate? {
        NSApplication.shared.delegate as? AppDelegate
    }

    private var miniPlayerAspectRatio: CGFloat {
        guard let observedRatio = self.playerService.miniPlayerVideoAspectRatio else {
            return Layout.miniPlayerDefaultAspectRatio
        }

        return min(
            max(CGFloat(observedRatio), Layout.miniPlayerMinAspectRatio),
            Layout.miniPlayerMaxAspectRatio
        )
    }

    var body: some View {
        @Bindable var player = self.playerService

        ZStack(alignment: .bottomTrailing) {
            if self.playerService.showFullscreenNowPlaying {
                Group {
                    if self.authService.state.isInitializing {
                        self.initializingView
                    } else if self.authService.state.isLoggedIn {
                        self.mainContent
                    } else {
                        OnboardingView()
                    }
                }
                .hidden()
                .allowsHitTesting(false)
            } else {
                Group {
                    if self.authService.state.isInitializing {
                        // Show loading while checking login status to avoid onboarding flash
                        self.initializingView
                    } else if self.authService.state.isLoggedIn {
                        self.mainContent
                    } else {
                        OnboardingView()
                    }
                }
                .allowsHitTesting(true)
                .animation(.easeInOut(duration: 0.2), value: self.playerService.showFullscreenNowPlaying)
            }

            // Persistent WebView - always present once a video has been requested
            // Uses a SINGLETON WebView instance that persists for the app lifetime
            // The mini player can be resized by dragging any edge.
            if let videoId = playerService.pendingPlayVideoId {
                let isMiniPlayerVisible = !self.playerService.showFullscreenNowPlaying && self.playerService.showMiniPlayer
                let miniPlayerHeight = self.miniPlayerWidth / self.miniPlayerAspectRatio
                let shouldPreferVideo = self.playerService.currentTrackHasVideo
                    || self.playerService.miniPlayerVideoAspectRatio != nil

                PersistentPlayerView(
                    videoId: videoId,
                    isExpanded: isMiniPlayerVisible,
                    prefersVideo: shouldPreferVideo,
                    viewportSize: CGSize(width: self.miniPlayerWidth, height: miniPlayerHeight)
                )
                .frame(
                    width: self.playerService.showFullscreenNowPlaying ? 1 : (isMiniPlayerVisible ? self.miniPlayerWidth : 1),
                    height: self.playerService.showFullscreenNowPlaying ? 1 : (isMiniPlayerVisible ? miniPlayerHeight : 1)
                )
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .opacity(isMiniPlayerVisible ? 0.95 : 0)
                .overlay {
                    if isMiniPlayerVisible {
                        self.miniPlayerResizeOverlay
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isMiniPlayerVisible {
                        Button {
                            self.playerService.confirmPlaybackStarted()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.8))
                                .shadow(radius: 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Close"))
                        .padding(3)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if isMiniPlayerVisible, self.shouldShowNoVideoHint {
                        Text(String(localized: "No video available for this track"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.22), in: Capsule())
                            .padding(.leading, 8)
                            .padding(.bottom, 8)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .shadow(
                    color: isMiniPlayerVisible ? .black.opacity(0.2) : .clear,
                    radius: 6,
                    y: 3
                )
                .padding(.trailing, isMiniPlayerVisible ? 12 : 0)
                .padding(.bottom, isMiniPlayerVisible ? 76 : 0)
                .allowsHitTesting(isMiniPlayerVisible)
                .animation(.easeInOut(duration: 0.2), value: isMiniPlayerVisible)
                .animation(.easeInOut(duration: 0.18), value: self.shouldShowNoVideoHint)
            }
        }
        .sheet(isPresented: self.$showLoginSheet) {
            LoginSheet()
        }
        .sheet(item: self.$whatsNewToPresent) { presentedWhatsNew in
            WhatsNewView(whatsNew: presentedWhatsNew.whatsNew) {
                self.dismissWhatsNew(presentedWhatsNew)
            }
        }
        .overlay {
            // Command bar overlay - dismisses when clicking outside
            if self.isCommandBarPresented, !self.playerService.showFullscreenNowPlaying {
                ZStack {
                    // Background tap area to dismiss
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .accessibilityIdentifier(AccessibilityID.MainWindow.commandBarOverlay)
                        .onTapGesture {
                            self.isCommandBarPresented = false
                        }

                    VStack(spacing: 0) {
                        CommandBarView(client: self.client, isPresented: self.$isCommandBarPresented)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, Self.Layout.commandBarTopPadding)
                }
                .animation(.easeInOut(duration: 0.15), value: self.isCommandBarPresented)
            }
        }
        .overlay(alignment: .top) {
            // Error toast for account switching failures
            if !self.playerService.showFullscreenNowPlaying {
                AccountErrorToast()
                    .padding(.top, 60)
            }
        }
        .overlay {
            if self.playerService.showFullscreenNowPlaying {
                FullscreenNowPlayingView(client: self.client)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(10)
            }
        }
        .toolbarVisibility(
            self.playerService.showFullscreenNowPlaying ? .hidden : .automatic,
            for: .automatic
        )
        .toolbarBackgroundVisibility(
            self.playerService.showFullscreenNowPlaying ? .hidden : .automatic,
            for: .windowToolbar
        )
        .onAppear {
            self.updateWindowTitleVisibility(for: self.playerService.showFullscreenNowPlaying)
        }
        .onChange(of: self.playerService.showFullscreenNowPlaying) { _, isShown in
            self.updateWindowTitleVisibility(for: isShown)
        }
        .onChange(of: self.showCommandBar.wrappedValue) { _, newValue in
            if newValue {
                self.isCommandBarPresented = true
                self.showCommandBar.wrappedValue = false
            }
        }
        .onChange(of: self.showWhatsNew.wrappedValue) { _, newValue in
            if newValue {
                // Manual trigger from Help menu — fetch release notes, bypass version store
                Task { @MainActor in
                    await self.presentCurrentWhatsNew(
                        respectingPresentedVersions: false,
                        allowsGenericFallback: true
                    )
                }
                self.showWhatsNew.wrappedValue = false
            }
        }
        .onChange(of: self.authService.state) { oldState, newState in
            self.handleAuthStateChange(oldState: oldState, newState: newState)
        }
        .onChange(of: self.authService.needsReauth) { _, needsReauth in
            if needsReauth {
                self.showLoginSheet = true
            }
        }
        .onChange(of: self.playerService.isPlaying) { _, isPlaying in
            if isPlaying {
                self.playerService.handlePlaybackStartedForMiniPlayer()
            }
        }
        .onChange(of: self.accountService.currentAccount?.id) { _, newAccountId in
            self.playerService.resetTrackStatus()

            Task { @MainActor in
                APICache.shared.invalidateAll()
                URLCache.shared.removeAllCachedResponses()

                guard newAccountId != nil else { return }

                self.historyViewModel?.reset()

                DiagnosticsLogger.auth.info("Account switched, refreshing content and current track metadata...")

                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await self.refreshAllContent()
                    }

                    if let currentVideoId = self.playerService.currentTrack?.videoId {
                        group.addTask {
                            await self.playerService.fetchSongMetadata(videoId: currentVideoId)
                        }
                    }
                }
            }
        }
        .task {
            NowPlayingManager.shared.configure(playerService: self.playerService)
        }
        .onChange(of: self.likeStatusManager.lastLikeEvent) { _, event in
            guard let event else { return }

            // Keep PlayerService.currentTrackLikeStatus in sync.
            if let currentVideoId = self.playerService.currentTrack?.videoId,
               event.videoId == currentVideoId
            {
                self.playerService.currentTrackLikeStatus = event.status
            }
        }
    }

    private func updateWindowTitleVisibility(for isFullscreenNowPlaying: Bool) {
        guard let window = NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first(where: { $0.isMainWindow })
            ?? NSApplication.shared.windows.first(where: { $0.canBecomeMain })
        else {
            return
        }

        window.titleVisibility = isFullscreenNowPlaying ? .hidden : .visible
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ZStack(alignment: .trailing) {
            // Main navigation content
            NavigationSplitView(columnVisibility: self.$columnVisibility) {
                Sidebar(selection: self.$navigationSelection)
                    .environment(self.libraryViewModel)
            } detail: {
                self.detailView(for: self.navigationSelection, client: self.client)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                // Ensure sidebar is visible when window becomes key (e.g., restored from dock)
                if self.columnVisibility != .all {
                    self.columnVisibility = .all
                }
            }

            // Right sidebar overlay - either lyrics or queue (mutually exclusive)
            self.rightSidebarOverlay(client: self.client)
        }
        .frame(minWidth: 900, minHeight: 600)
        .toolbarVisibility(
            self.playerService.showFullscreenNowPlaying ? .hidden : .automatic,
            for: .automatic
        )
        .toolbarBackgroundVisibility(
            self.playerService.showFullscreenNowPlaying ? .hidden : .automatic,
            for: .automatic
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    self.isCommandBarPresented = true
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                }
                .keyboardShortcut("k", modifiers: .command)
                .help(String(localized: "Ask AI (⌘K)"))
                .accessibilityIdentifier(AccessibilityID.MainWindow.aiButton)
                .requiresIntelligence()
            }
        }
        .toolbar(removing: .sidebarToggle)
    }

    /// Right sidebar overlay showing either lyrics or queue as glass panels (mutually exclusive).
    @ViewBuilder
    private func rightSidebarOverlay(client: any YTMusicClientProtocol) -> some View {
        let showRightSidebar = (self.playerService.showLyrics || self.playerService.showQueue)
            && !self.playerService.showFullscreenNowPlaying

        if showRightSidebar {
            VStack {
                Spacer()

                Group {
                    if self.playerService.showLyrics {
                        LyricsView(client: client)
                    } else if self.playerService.showQueue {
                        if self.playerService.queueDisplayMode == .sidepanel {
                            QueueSidePanelView()
                        } else {
                            QueueView()
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .padding(.top, 12)
                .padding(.bottom, 76) // Space for PlayerBar
                .transition(.move(edge: .trailing).combined(with: .opacity))

                Spacer()
            }
            .padding(.trailing, 16)
        }
    }

    private var miniPlayerResizeOverlay: some View {
        MiniPlayerResizeOverlayView(
            width: self.$miniPlayerWidth,
            aspectRatio: self.miniPlayerAspectRatio,
            minWidth: Layout.miniPlayerMinWidth,
            maxWidth: Layout.miniPlayerMaxWidth,
            edgeThickness: Layout.miniPlayerResizeEdgeThickness
        )
    }

    private var shouldShowNoVideoHint: Bool {
        self.playerService.showMiniPlayer
            && self.playerService.pendingPlayVideoId != nil
            && (!self.playerService.currentTrackHasVideo || self.playerService.miniPlayerVideoAspectRatio == nil)
    }

    private func detailView(for selection: SidebarSelection?, client _: any YTMusicClientProtocol) -> some View {
        Group {
            if let selection {
                self.viewForSidebarSelection(selection)
            } else {
                Text("Select an item from the sidebar", comment: "Placeholder shown when no sidebar item is selected")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func viewForSidebarSelection(_ selection: SidebarSelection) -> some View {
        Group {
            switch selection {
            case let .navigation(item):
                self.viewForNavigationItem(item)
            case let .playlist(playlistId):
                let playlist = self.sidebarPlaylist(for: playlistId)
                PlaylistDetailView(
                    playlist: playlist,
                    viewModel: PlaylistDetailViewModel(playlist: playlist, client: self.client)
                )
                .id(playlist.id)
            }
        }
    }

    private func sidebarPlaylist(for playlistId: String) -> Playlist {
        guard let libraryViewModel else {
            return Playlist(
                id: playlistId,
                title: String(localized: "Playlist"),
                description: nil,
                thumbnailURL: nil,
                trackCount: nil,
                author: nil
            )
        }

        let normalizedPlaylistId = Self.normalizedPlaylistId(playlistId)
        if let playlist = libraryViewModel.playlists.first(where: { Self.normalizedPlaylistId($0.id) == normalizedPlaylistId }) {
            return playlist
        }

        return Playlist(
            id: playlistId,
            title: String(localized: "Playlist"),
            description: nil,
            thumbnailURL: nil,
            trackCount: nil,
            author: nil
        )
    }

    private static func normalizedPlaylistId(_ playlistId: String) -> String {
        if playlistId.hasPrefix("VL") {
            return String(playlistId.dropFirst(2))
        }
        return playlistId
    }

    /// Returns the view for a specific navigation item.
    private func viewForNavigationItem(_ item: NavigationItem) -> some View { // swiftlint:disable:this cyclomatic_complexity
        Group {
            switch item {
            case .home:
                if let vm = homeViewModel { HomeView(viewModel: vm) }
            case .explore:
                if let vm = exploreViewModel { ExploreView(viewModel: vm) }
            case .search:
                if let vm = searchViewModel { SearchView(viewModel: vm) }
            case .charts:
                if let vm = chartsViewModel { ChartsView(viewModel: vm) }
            case .moodsAndGenres:
                if let vm = moodsAndGenresViewModel { MoodsAndGenresView(viewModel: vm) }
            case .newReleases:
                if let vm = newReleasesViewModel { NewReleasesView(viewModel: vm) }
            case .podcasts:
                if let vm = podcastsViewModel { PodcastsView(viewModel: vm) }
            case .likedMusic:
                PlaylistDetailView(
                    playlist: self.likedMusicPlaylist,
                    viewModel: PlaylistDetailViewModel(playlist: self.likedMusicPlaylist, client: self.client)
                )
            case .library:
                if let vm = libraryViewModel { LibraryView(viewModel: vm) }
            case .history:
                if let vm = historyViewModel { HistoryView(viewModel: vm) }
            }
        }
        .environment(self.libraryViewModel)
    }

    /// View shown while checking initial login status.
    private var initializingView: some View {
        VStack(spacing: 16) {
            CassetteIcon(size: 60)
                .foregroundStyle(.tint)
            ProgressView()
                .controlSize(.regular)
                .frame(width: 20, height: 20)
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    private func handleAuthStateChange(oldState: AuthService.State, newState: AuthService.State) {
        switch newState {
        case .initializing:
            // Still checking login status, do nothing
            break
        case .loggedOut:
            // Onboarding view handles login, no need to auto-show sheet
            self.accountService.clearAccounts()
        case .loggingIn:
            self.showLoginSheet = true
        case .loggedIn:
            self.showLoginSheet = false
            // Auto-present "What's New" — fetch from GitHub release notes
            if self.whatsNewToPresent == nil {
                Task { @MainActor in
                    await self.presentCurrentWhatsNew()
                }
            }
            Task {
                await self.accountService.fetchAccounts()
            }
            // If we just completed login (transitioning from loggingIn), refresh content
            // This handles the case where cookies weren't ready during initial load
            if case .loggingIn = oldState {
                Task {
                    // Brief delay to ensure cookies are fully propagated in WebKit
                    try? await Task.sleep(for: .milliseconds(500))

                    // Parallel initial data fetch for ~40% faster app launch
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { await self.homeViewModel?.refresh() }
                        group.addTask { await self.exploreViewModel?.refresh() }
                        group.addTask { await self.libraryViewModel?.load() }
                    }
                }
            }
        }
    }

    @MainActor
    private func dismissWhatsNew(_ whatsNew: PresentedWhatsNew) {
        WhatsNewVersionStore().markPresented(whatsNew.requestedVersion)
        self.whatsNewToPresent = nil
    }

    @MainActor
    private func presentCurrentWhatsNew(
        respectingPresentedVersions: Bool = true,
        allowsGenericFallback: Bool = false
    ) async {
        let currentVersion = WhatsNew.Version.current()
        let whatsNew = await WhatsNewProvider.fetchWhatsNew(
            for: currentVersion,
            respectingPresentedVersions: respectingPresentedVersions
        ) ?? (allowsGenericFallback ? WhatsNewProvider.fallbackCollection.first : nil)

        guard let whatsNew else { return }

        self.whatsNewToPresent = PresentedWhatsNew(
            whatsNew: whatsNew,
            requestedVersion: currentVersion
        )
    }

    /// Refreshes all content when switching accounts.
    ///
    /// This method is called when the user switches between their primary account
    /// and brand accounts, ensuring all views display content for the new account.
    private func refreshAllContent() async {
        // Parallel refresh of all content views
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.homeViewModel?.refresh() }
            group.addTask { await self.exploreViewModel?.refresh() }
            group.addTask { await self.chartsViewModel?.refresh() }
            group.addTask { await self.moodsAndGenresViewModel?.refresh() }
            group.addTask { await self.newReleasesViewModel?.refresh() }
            group.addTask { await self.podcastsViewModel?.refresh() }
            group.addTask { await self.historyViewModel?.load() }
            group.addTask { await self.libraryViewModel?.refresh() }
        }
    }
}

// MARK: - NavigationItem

enum NavigationItem: String, Hashable, CaseIterable, Identifiable {
    case home = "Home"
    case explore = "Explore"
    case search = "Search"
    case charts = "Charts"
    case moodsAndGenres = "Moods & Genres"
    case newReleases = "New Releases"
    case podcasts = "Podcasts"
    case likedMusic = "Liked Music"
    case library = "Library"
    case history = "History"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .home:
            String(localized: "Home")
        case .explore:
            String(localized: "Explore")
        case .search:
            String(localized: "Search")
        case .charts:
            String(localized: "Charts")
        case .moodsAndGenres:
            String(localized: "Moods & Genres")
        case .newReleases:
            String(localized: "New Releases")
        case .podcasts:
            String(localized: "Podcasts")
        case .likedMusic:
            String(localized: "Liked Music")
        case .library:
            String(localized: "Library")
        case .history:
            String(localized: "History")
        }
    }

    var icon: String {
        switch self {
        case .home:
            "house"
        case .explore:
            "globe"
        case .search:
            "magnifyingglass"
        case .charts:
            "chart.line.uptrend.xyaxis"
        case .moodsAndGenres:
            "theatermask.and.paintbrush"
        case .newReleases:
            "sparkles"
        case .podcasts:
            "mic.fill"
        case .likedMusic:
            "heart.fill"
        case .library:
            "square.stack.fill"
        case .history:
            "clock.arrow.circlepath"
        }
    }
}

enum SidebarSelection: Hashable {
    case navigation(NavigationItem)
    case playlist(String)
}

@available(macOS 26.0, *)
#Preview {
    @Previewable @State var navSelection: SidebarSelection? = .navigation(.home)
    let authService = AuthService()
    let ytMusicClient = YTMusicClient(authService: authService)
    let accountService = AccountService(ytMusicClient: ytMusicClient, authService: authService)
    MainWindow(navigationSelection: $navSelection, client: ytMusicClient)
        .environment(authService)
        .environment(PlayerService())
        .environment(WebKitManager.shared)
        .environment(accountService)
}

private struct MiniPlayerResizeOverlayView: NSViewRepresentable {
    @Binding var width: CGFloat

    let aspectRatio: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let edgeThickness: CGFloat

    func makeNSView(context: Context) -> MiniPlayerResizeView {
        let view = MiniPlayerResizeView(frame: .zero)
        view.onWidthChange = { newWidth in
            self.width = newWidth
        }
        return view
    }

    func updateNSView(_ nsView: MiniPlayerResizeView, context _: Context) {
        nsView.currentWidth = self.width
        nsView.aspectRatio = self.aspectRatio
        nsView.minWidth = self.minWidth
        nsView.maxWidth = self.maxWidth
        nsView.edgeThickness = self.edgeThickness
        nsView.onWidthChange = { newWidth in
            self.width = newWidth
        }
        nsView.needsDisplay = true
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private final class MiniPlayerResizeView: NSView {
    enum ResizeEdge {
        case left
        case right
        case top
        case bottom
    }

    var currentWidth: CGFloat = 320
    var aspectRatio: CGFloat = 16.0 / 9.0
    var minWidth: CGFloat = 220
    var maxWidth: CGFloat = 760
    var edgeThickness: CGFloat = 24
    var onWidthChange: ((CGFloat) -> Void)?

    private var activeEdge: ResizeEdge?
    private var dragStartPoint: NSPoint = .zero
    private var dragStartWidth: CGFloat = 320

    override func hitTest(_ point: NSPoint) -> NSView? {
        self.edge(at: point) == nil ? nil : self
    }

    override func resetCursorRects() {
        self.discardCursorRects()

        let edge = self.edgeThickness
        let horizontalWidth = max(self.bounds.width - (2 * edge), 1)
        let verticalHeight = max(self.bounds.height - (2 * edge), 1)

        self.addCursorRect(
            NSRect(x: edge, y: self.bounds.height - edge, width: horizontalWidth, height: edge),
            cursor: .resizeUpDown
        )
        self.addCursorRect(
            NSRect(x: edge, y: 0, width: horizontalWidth, height: edge),
            cursor: .resizeUpDown
        )
        self.addCursorRect(
            NSRect(x: 0, y: edge, width: edge, height: verticalHeight),
            cursor: .resizeLeftRight
        )
        self.addCursorRect(
            NSRect(x: self.bounds.width - edge, y: edge, width: edge, height: verticalHeight),
            cursor: .resizeLeftRight
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)
        guard let edge = self.edge(at: point) else { return }

        self.activeEdge = edge
        self.dragStartPoint = point
        self.dragStartWidth = self.currentWidth
    }

    override func mouseDragged(with event: NSEvent) {
        guard let activeEdge else { return }

        let point = self.convert(event.locationInWindow, from: nil)
        let deltaX = point.x - self.dragStartPoint.x
        let deltaY = point.y - self.dragStartPoint.y

        let dominantDelta: CGFloat = switch activeEdge {
        case .left:
            -deltaX
        case .right:
            deltaX
        case .top:
            deltaY * self.aspectRatio
        case .bottom:
            -deltaY * self.aspectRatio
        }

        let proposedWidth = self.dragStartWidth + dominantDelta
        let clampedWidth = min(max(proposedWidth, self.minWidth), self.maxWidth)
        self.onWidthChange?(clampedWidth)
    }

    override func mouseUp(with _: NSEvent) {
        self.activeEdge = nil
    }

    private func edge(at point: NSPoint) -> ResizeEdge? {
        let edge = self.edgeThickness
        let leftDistance = point.x
        let rightDistance = self.bounds.width - point.x
        let topDistance = self.bounds.height - point.y
        let bottomDistance = point.y

        let candidates: [(ResizeEdge, CGFloat)] = [
            (.left, leftDistance),
            (.right, rightDistance),
            (.top, topDistance),
            (.bottom, bottomDistance),
        ]

        guard let nearest = candidates.min(by: { $0.1 < $1.1 }), nearest.1 <= edge else {
            return nil
        }

        return nearest.0
    }
}
