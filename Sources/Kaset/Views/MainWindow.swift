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
        /// Minimum width the navigation sidebar plus its detail content need. The Now Playing sidebar
        /// is laid out *beside* this, so the window's own minimum grows by the column's width and the
        /// content can never be squeezed or cut off while the column is open.
        static let detailMinWidth: CGFloat = 900
        /// Widths of the Now Playing sidebar column. The reader can drag it between these, the way
        /// every other sidebar in the app behaves.
        static let nowPlayingSidebarMinWidth: CGFloat = 300
        static let nowPlayingSidebarIdealWidth: CGFloat = 380
        static let nowPlayingSidebarMaxWidth: CGFloat = 560
        /// Hit area of the draggable edge between the content and the Now Playing sidebar.
        static let nowPlayingSidebarHandleWidth: CGFloat = 8
        /// Absolute floor for the column when the window is too narrow even for its minimum width.
        /// Below this the content wins, so the window stays usable on a small display.
        static let nowPlayingSidebarFloorWidth: CGFloat = 240
        /// Minimum content height of the window.
        static let minimumContentHeight: CGFloat = 600
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
    /// Observed so switching the right sidebar design carries the open panel over instead of
    /// leaving the overlay empty.
    @State private var settings = SettingsManager.shared
    @State private var whatsNewToPresent: PresentedWhatsNew?
    @State private var miniPlayerWidth: CGFloat = Layout.miniPlayerDefaultWidth

    /// Width the column is being dragged to *right now* (`nil` when no drag is in progress).
    ///
    /// Kept in view state rather than in `SettingsManager`: writing the setting persists to
    /// `UserDefaults` and re-renders the whole window on every mouse-move event, which is what made
    /// resizing feel like it was fighting the drag. The value is persisted once, on drag end.
    @State private var liveColumnWidth: CGFloat?
    /// Width the detail area is actually offered, measured so the column can be clamped to it.
    @State private var contentAreaWidth: CGFloat = 0

    /// Video state the fullscreen podcast experience shares with the layer below.
    /// Owned here because this view owns the WebView layer.
    @State private var podcastVideoPreferences = PodcastVideoPreferences()

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
        let showsPodcastFullscreen = self.playerService.isFullscreenPodcastPresented

        ZStack(alignment: .bottomTrailing) {
            // Flag-driven modifiers on a single `Group`, never an `if/else` on the fullscreen flag: two
            // branches have different structural identities, so every fullscreen open/close tore down
            // and rebuilt the whole screen tree — resetting the `PlayerBar`'s artwork (and scroll
            // positions) and making the now-playing art fall back to its placeholder on both
            // transitions. One identity keeps the state of every screen underneath alive, which in turn
            // is why the obscured subtree must be disabled (see `FullscreenObscureModifier`) and why the
            // fullscreen view itself is presentation-driven rather than rebuild-driven.
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
            .modifier(FullscreenObscureModifier(isObscured: self.playerService.showFullscreenNowPlaying))

            // The podcast experience sits *below* the WebView layer: it declares where the video
            // belongs and the shared layer is placed into that slot, which is how the episode video
            // appears on the left without the transcript view ever owning playback.
            if showsPodcastFullscreen {
                FullscreenPodcastView(videoPreferences: self.podcastVideoPreferences)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(9)
            }

            // Persistent WebView - present as soon as the app is signed in, not only once a video
            // has been requested, so the YouTube Music shell can be preloaded before the first play
            // (see `PlayerWebViewPreload`). Uses a SINGLETON WebView instance that persists for the
            // app lifetime. The mini player can be resized by dragging any edge.
            if self.hostsPlayerWebView(showsPodcastFullscreen: showsPodcastFullscreen) {
                self.miniPlayerLayer(videoId: playerService.pendingPlayVideoId)
            }
        }
        // The episode video is drawn in an overlay rather than as a stack child: the fullscreen
        // podcast view covers the whole window, so the layer has to stack *above* it, and resolving
        // the slot's anchor here — against the same container the layer is placed in — is what keeps
        // the video exactly on its slot.
        .overlayPreferenceValue(PodcastVideoSlotAnchor.self) { anchor in
            GeometryReader { proxy in
                if showsPodcastFullscreen,
                   self.showsWebLayer,
                   let videoId = playerService.pendingPlayVideoId
                {
                    self.podcastVideoLayer(videoId: videoId, slot: anchor.map { proxy[$0] } ?? .zero)
                }
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
            // Podcast episodes get the listening experience above; songs keep artwork + lyrics.
            if self.playerService.showFullscreenNowPlaying, !self.playerService.isCurrentTrackPodcast {
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
            self.scheduleWindowMinimumUpdate()
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
        .onChange(of: self.settings.nowPlayingSidebarEnabled) { _, isEnabled in
            self.handleSidebarStyleChange(isNowPlayingSidebarEnabled: isEnabled)
            self.scheduleWindowMinimumUpdate()
        }
        .onChange(of: self.playerService.isNowPlayingSidebarVisible) { _, _ in
            self.scheduleWindowMinimumUpdate()
        }
        .onChange(of: self.settings.nowPlayingSidebarWidth) { _, _ in
            self.scheduleWindowMinimumUpdate()
        }
        .onChange(of: self.navigationSelection) { _, _ in
            // The navigation sidebar can be collapsed, which changes how much width the content needs.
            self.scheduleWindowMinimumUpdate()
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
        // TEMPORARY: scroll diagnostics (see PerfHUD).
        .overlay(alignment: .topLeading) {
            if PerfHUD.isEnabled {
                PerfHUDOverlay()
            }
        }
        .task {
            PerfHUD.shared.start()
        }
    }

    /// Defers the window minimum update to the next runloop tick so it never mutates the window mid
    /// SwiftUI update (which is exactly the kind of re-entrant layout that aborts the app).
    private func scheduleWindowMinimumUpdate() {
        Task { @MainActor in
            self.applyWindowMinimumSize()
        }
    }

    /// Carries the open right sidebar over when the design changes in Settings.
    ///
    /// Without this the panel simply vanishes on the switch: each design reads its own presentation
    /// state, so the new one has nothing open while the old one stops being rendered.
    private func handleSidebarStyleChange(isNowPlayingSidebarEnabled: Bool) {
        if isNowPlayingSidebarEnabled {
            guard self.playerService.showLyrics || self.playerService.showQueue else { return }
            self.playerService.setNowPlayingSidebarPage(.overview)
        } else {
            self.playerService.closeNowPlayingSidebar()
        }
    }

    /// TEMPORARY: honors the PerfHUD "WebLayer" switch.
    private var showsWebLayer: Bool {
        !PerfHUD.isEnabled || PerfHUD.shared.showsWebLayer
    }

    /// Whether the player layer should be hosted at all.
    ///
    /// Signed-in sessions host it from launch, which is what gives the shell somewhere to preload;
    /// a pending video (a queue song, or a restored session waiting to resume) needs it regardless.
    private func hostsPlayerWebView(showsPodcastFullscreen: Bool) -> Bool {
        guard self.showsWebLayer, !showsPodcastFullscreen else { return false }
        return PlayerWebViewPreload.shouldHostPlayerWebView(
            isSignedIn: self.authService.state.isLoggedIn,
            hasPendingVideo: self.playerService.pendingPlayVideoId != nil
        )
    }

    // MARK: - Player WebView Layer

    /// The floating mini player, resizable by dragging any edge. `videoId` is `nil` until a track is
    /// asked for; the layer is still hosted then, purely so the WebView can preload.
    @ViewBuilder
    private func miniPlayerLayer(videoId: String?) -> some View {
        let isMiniPlayerVisible = !self.playerService.showFullscreenNowPlaying && self.playerService.showMiniPlayer
        let miniPlayerHeight = self.miniPlayerWidth / self.miniPlayerAspectRatio

        PersistentPlayerView(
            videoId: videoId,
            isExpanded: isMiniPlayerVisible,
            prefersVideo: self.playerService.hasVideoSurface,
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

    /// The episode video surface, placed on the slot the fullscreen podcast view declared.
    ///
    /// The presentation stays *expanded* for the whole podcast session, even while the video is
    /// hidden and even before the slot is known: that is what keeps the `<video>` element extracted
    /// into the page's video container. Handing it back to YouTube and re-extracting it on every
    /// toggle is what made switching the video off blank the slot and switching it back on never
    /// bring the picture back. Only the layer's opacity follows the toggle, so the round trip is
    /// instant, and the container's percentage sizing follows the layer's frame when the slot
    /// resizes.
    @ViewBuilder
    private func podcastVideoLayer(videoId: String, slot: CGRect) -> some View {
        let hasSlot = slot.width >= 1 && slot.height >= 1
        let hasVideo = self.playerService.hasVideoSurface
        let placesVideo = hasSlot && hasVideo
        let showsVideo = placesVideo && self.podcastVideoPreferences.isVideoEnabled

        PersistentPlayerView(
            videoId: videoId,
            isExpanded: true,
            prefersVideo: hasVideo,
            viewportSize: placesVideo ? slot.size : CGSize(width: 1, height: 1)
        )
        .frame(width: placesVideo ? slot.width : 1, height: placesVideo ? slot.height : 1)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .position(x: placesVideo ? slot.midX : -100, y: placesVideo ? slot.midY : -100)
        .opacity(showsVideo ? 1 : 0)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.22), value: showsVideo)
    }

    /// Hides the root content behind the fullscreen now-playing overlay, which covers the whole window.
    ///
    /// The flag only drives modifiers — it must never select a different view branch, because switching
    /// branches changes the content's structural identity and rebuilds every screen underneath on each
    /// fullscreen transition (which reset the now-playing artwork in the `PlayerBar`).
    private struct FullscreenObscureModifier: ViewModifier {
        let isObscured: Bool

        func body(content: Content) -> some View {
            content
                .opacity(self.isObscured ? 0 : 1)
                .allowsHitTesting(!self.isObscured)
                // Hidden content has to be *inert*, not merely invisible. Because the content tree now
                // survives the overlay, keyboard focus survives with it: a text field that still holds
                // focus would keep receiving keystrokes behind the fullscreen view, and the player bar's
                // hidden Space/arrow shortcuts would compete with the app's Playback menu commands.
                // Disabling the subtree resigns that focus and blocks keyboard activation; nothing in the
                // content reads `.isEnabled` for behavior, and the disabled appearance is invisible here.
                .disabled(self.isObscured)
                .animation(.easeInOut(duration: 0.2), value: self.isObscured)
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
            // Main navigation content, with the Now Playing sidebar as a real trailing column beside
            // it — the same structure as the navigation sidebar, not a panel floating over the
            // content.
            //
            // It is deliberately *not* the system inspector: SwiftUI's `.inspector` nests an
            // NSSplitViewController inside the NavigationSplitView, and resizing that nested
            // controller invalidates constraints re-entrantly mid display cycle, which aborts the
            // app. This column is a plain HStack child, so it cannot perturb the split view's layout.
            HStack(spacing: 0) {
                NavigationSplitView(columnVisibility: self.$columnVisibility) {
                    Sidebar(selection: self.$navigationSelection)
                        .environment(self.libraryViewModel)
                } detail: {
                    self.detailView(for: self.navigationSelection, client: self.client)
                }
                // The navigation sidebar plus its content keep their own minimum; the HStack then
                // carries the window's minimum past this by the column's width, so the column can
                // never push the content off screen.
                .frame(minWidth: Layout.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .trailing) {
                    // The draggable edge lives on the content's trailing edge so it sits exactly on
                    // the boundary and its hit area is inside the content rather than a gutter.
                    if self.playerService.isNowPlayingSidebarVisible {
                        NowPlayingSidebarResizeHandle(
                            width: self.columnWidthBinding,
                            minWidth: Layout.nowPlayingSidebarMinWidth,
                            maxWidth: Layout.nowPlayingSidebarMaxWidth,
                            onCommit: { self.commitColumnWidth() }
                        )
                        .frame(width: Layout.nowPlayingSidebarHandleWidth)
                        .accessibilityHidden(true)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                    // Ensure sidebar is visible when window becomes key (e.g., restored from dock)
                    if self.columnVisibility != .all {
                        self.columnVisibility = .all
                    }
                }

                if self.playerService.isNowPlayingSidebarVisible {
                    // The width is authoritative and passed in: the sidebar sizes its own content from
                    // this, never from a second measurement of itself, so a resize cannot leave the
                    // column and its contents one frame out of step with each other.
                    NowPlayingSidebarView(columnWidth: self.effectiveColumnWidth)
                        .frame(width: self.effectiveColumnWidth)
                }
            }
            // The `HStack`'s own width is the space available to the detail area. Measuring it here —
            // not the overflowed children — is what lets the column be clamped so the stack always
            // fits. It is measured rather than assumed so a window resize (or a display change) keeps
            // the clamp correct.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
                self.contentAreaWidth = newWidth
            }

            // Classic lyrics/queue panels, floating over the content (mutually exclusive).
            self.classicSidebarOverlay(client: self.client)
        }
        .frame(minWidth: Layout.detailMinWidth, minHeight: 600)
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

            // The Now Playing sidebar's toggle, styled like the content's own toolbar buttons.
            //
            // It lives in the toolbar only while the column is *closed* — its resting place, at the
            // window's trailing edge, where the column's top-right corner will be. Once the column is
            // open the toggle moves into the column itself (see `NowPlayingSidebarView`), so the toolbar
            // keeps exactly one set of controls, at the trailing edge, and the column contains the only
            // button that belongs to it.
            if self.playerService.isNowPlayingSidebarEnabled, !self.playerService.isNowPlayingSidebarVisible {
                ToolbarItem(placement: .primaryAction) {
                    NowPlayingSidebarToggle {
                        withAnimation(AppAnimation.standard) {
                            self.playerService.setNowPlayingSidebarPage(.overview)
                        }
                    }
                }
            }
        }
        .toolbar(removing: .sidebarToggle)
    }

    /// The width the column *wants*: what the reader is dragging to right now, or the persisted width.
    ///
    /// The stored value is clamped on read so a bobbled write can never wedge the column off screen.
    private var desiredColumnWidth: CGFloat {
        if let live = self.liveColumnWidth { return live }
        let stored = CGFloat(self.settings.nowPlayingSidebarWidth)
        guard stored.isFinite, stored > 0 else { return Layout.nowPlayingSidebarIdealWidth }
        return min(max(stored, Layout.nowPlayingSidebarMinWidth), Layout.nowPlayingSidebarMaxWidth)
    }

    /// The column's width arithmetic, as one value: the measured space plus the window's own limits.
    private var columnGeometry: NowPlayingSidebarColumnGeometry {
        NowPlayingSidebarColumnGeometry(
            availableWidth: self.contentAreaWidth,
            detailMinWidth: Layout.detailMinWidth,
            handleWidth: Layout.nowPlayingSidebarHandleWidth,
            minWidth: Layout.nowPlayingSidebarMinWidth,
            maxWidth: Layout.nowPlayingSidebarMaxWidth,
            floorWidth: Layout.nowPlayingSidebarFloorWidth
        )
    }

    /// The width the column actually occupies. Never wider than the space admits (so the content keeps
    /// its minimum), never narrower than the box the sidebar's own content is designed around.
    private var effectiveColumnWidth: CGFloat {
        self.columnGeometry.effective(desired: self.desiredColumnWidth)
    }

    /// Reads and writes the column width while the divider is being dragged.
    ///
    /// The drag deliberately never touches `SettingsManager`: a write there persists to `UserDefaults`
    /// and re-renders the whole window on every mouse-move event, and it re-derives the window's
    /// minimum size mid-gesture — the two together are what made resizing feel like it was fighting
    /// back. Live width stays in view state; `commitColumnWidth()` persists it once, when the drag ends.
    private var columnWidthBinding: Binding<CGFloat> {
        Binding(
            get: { self.effectiveColumnWidth },
            set: { newValue in
                self.liveColumnWidth = self.columnGeometry.effective(desired: newValue)
            }
        )
    }

    /// Persists the dragged width once the drag ends, and re-applies the window minimum afterwards.
    ///
    /// The window is never resized *during* the drag: a minimum that tracked the live width made the
    /// window resize itself on every drag step, which is what cropped the content mid-gesture.
    private func commitColumnWidth() {
        defer { self.liveColumnWidth = nil }
        guard let width = self.liveColumnWidth else { return }
        self.settings.nowPlayingSidebarWidth = Double(width)
        self.scheduleWindowMinimumUpdate()
    }

    /// The window's own minimum content width: enough for the detail area and the column's *minimum*
    /// width.
    ///
    /// It deliberately does not track the column's current width. A minimum that grew with the column
    /// made the window try to resize itself on every drag step; a wider column instead gets clamped
    /// while the window is too narrow, and returns to its set width when the window is widened again —
    /// the way every resizable inspector behaves.
    private var minimumContentWidth: CGFloat {
        Layout.detailMinWidth
            + (self.playerService.isNowPlayingSidebarVisible
                ? Layout.nowPlayingSidebarHandleWidth + Layout.nowPlayingSidebarMinWidth
                : 0)
    }

    private var mainWindow: NSWindow? {
        NSApplication.shared.windows.first(where: { $0.frameAutosaveName == "KasetMainWindow" })
            ?? NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first(where: { $0.canBecomeMain })
    }

    /// Applies the window's minimum size explicitly.
    ///
    /// SwiftUI's `.frame(minWidth:)` on the content does not reliably reach the window's own
    /// `contentMinSize` in this shell, which let the window shrink until the column's cards were cut
    /// off at the right edge. Setting it on the window is unambiguous, and growing an already-open
    /// window that is now too small keeps the content whole the moment the column opens.
    private func applyWindowMinimumSize() {
        guard let window = self.mainWindow else { return }

        // Never demand more width than the display has: a window wider than its screen puts the
        // trailing column — and every toolbar button — off the edge where nothing can be reached.
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        let minimum = NSSize(
            width: min(self.minimumContentWidth, visible.width),
            height: min(Layout.minimumContentHeight, visible.height)
        )
        window.contentMinSize = minimum

        // What the window should *aim* for: at least its minimum, and — while the column is open —
        // wide enough for the column's current width too, so opening it or dropping the divider at its
        // widest never leaves the column clamped. This only runs on discrete events (open, close,
        // setting change, drag end), never between the steps of a drag.
        let fittingWidth = Layout.detailMinWidth
            + (self.playerService.isNowPlayingSidebarVisible
                ? Layout.nowPlayingSidebarHandleWidth + self.desiredColumnWidth
                : 0)

        let content = window.contentRect(forFrameRect: window.frame)
        let target = NSSize(
            width: min(max(content.width, min(fittingWidth, visible.width)), visible.width),
            height: min(max(content.height, minimum.height), visible.height)
        )
        guard target.width != content.width || target.height != content.height else { return }
        window.setContentSize(target)
    }

    /// The classic lyrics/queue panels as glass overlays (mutually exclusive).
    ///
    /// Which design the right sidebar uses is a Setting; both keep their own presentation state, so
    /// these panels are untouched for anyone who prefers them.
    @ViewBuilder
    private func classicSidebarOverlay(client: any YTMusicClientProtocol) -> some View {
        let showsClassicSidebar = !self.playerService.isNowPlayingSidebarEnabled
            && (self.playerService.showLyrics || self.playerService.showQueue)
            && !self.playerService.showFullscreenNowPlaying

        if showsClassicSidebar {
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
                // A stack is what makes the playlist's own links (artist, album) work when the
                // playlist is opened straight from the sidebar instead of a navigated list.
                DetailNavigationStack { path in
                    PlaylistDetailView(
                        playlist: playlist,
                        viewModel: PlaylistDetailViewModel(playlist: playlist, client: self.client),
                        onNavigateToArtist: { artist in path.wrappedValue.append(artist) }
                    )
                    .navigationDestinations(client: self.client, artistPath: path)
                }
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
    private func viewForNavigationItem(_ item: NavigationItem) -> some View {
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
                DetailNavigationStack { path in
                    PlaylistDetailView(
                        playlist: self.likedMusicPlaylist,
                        viewModel: PlaylistDetailViewModel(playlist: self.likedMusicPlaylist, client: self.client),
                        onNavigateToArtist: { artist in path.wrappedValue.append(artist) }
                    )
                    .navigationDestinations(client: self.client, artistPath: path)
                }
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

// MARK: - NowPlayingSidebarResizeHandle

/// The draggable edge between the content and the Now Playing sidebar.
///
/// A plain `NSView` rather than a SwiftUI drag gesture: it gives the resize cursor and a hit area
/// that does not need the column to reserve layout space, and dragging it only writes the column's
/// width — it never touches the split view, so it cannot re-enter the layout pass the way the
/// system inspector's resize does.
@available(macOS 26.0, *)
private struct NowPlayingSidebarResizeHandle: NSViewRepresentable {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    /// Called once, when the drag ends, so the width can be persisted without writing on every step.
    let onCommit: () -> Void

    func makeNSView(context _: Context) -> NowPlayingSidebarResizeView {
        let view = NowPlayingSidebarResizeView()
        view.currentWidth = self.width
        view.minWidth = self.minWidth
        view.maxWidth = self.maxWidth
        view.onWidthChange = { self.width = $0 }
        view.onCommit = self.onCommit
        return view
    }

    func updateNSView(_ nsView: NowPlayingSidebarResizeView, context _: Context) {
        nsView.currentWidth = self.width
        nsView.minWidth = self.minWidth
        nsView.maxWidth = self.maxWidth
        nsView.onWidthChange = { self.width = $0 }
        nsView.onCommit = self.onCommit
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

@available(macOS 26.0, *)
private final class NowPlayingSidebarResizeView: NSView {
    var currentWidth: CGFloat = 380
    var minWidth: CGFloat = 300
    var maxWidth: CGFloat = 560
    var onWidthChange: ((CGFloat) -> Void)?
    var onCommit: (() -> Void)?

    private var dragStartX: CGFloat = 0
    private var dragStartWidth: CGFloat = 380

    override func resetCursorRects() {
        self.addCursorRect(self.bounds, cursor: .resizeLeftRight)
    }

    override func draw(_: NSRect) {
        // A hairline on the trailing edge, where the column begins. The view itself is transparent, so
        // the strip over the content is only ever a hit target, never a visual gutter.
        let scale = self.window?.backingScaleFactor ?? 2
        let thickness = 1 / scale
        NSColor.separatorColor.setFill()
        NSRect(x: self.bounds.maxX - thickness, y: 0, width: thickness, height: self.bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
        self.dragStartX = event.locationInWindow.x
        self.dragStartWidth = self.currentWidth
    }

    override func mouseDragged(with event: NSEvent) {
        // Dragging left widens the column, so the delta runs from the pointer backwards.
        let delta = self.dragStartX - event.locationInWindow.x
        let newWidth = min(max(self.dragStartWidth + delta, self.minWidth), self.maxWidth)
        guard newWidth != self.currentWidth else { return }
        self.currentWidth = newWidth
        self.onWidthChange?(newWidth)
    }

    override func mouseUp(with _: NSEvent) {
        // One persist per gesture, not one per mouse-move event.
        self.onCommit?()
    }
}

// MARK: - MiniPlayerResizeOverlayView

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
