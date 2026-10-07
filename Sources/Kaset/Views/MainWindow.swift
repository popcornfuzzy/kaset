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
        /// The floor the window's own minimum has always been stated at, independent of which panes are
        /// open. See `WindowShellLayout.minWindowWidth` and `shellLayout`.
        static let detailMinWidth: CGFloat = 900

        /// The page's own minimum width: what the page's content needs before it crops.
        ///
        /// Measured in the running app, not guessed. With the Now Playing column open the split view sized
        /// itself to 200 + 765 + 300 — each of its three panes at its own floor — and **stayed** there while
        /// the window was narrower, which is the page drawn past the window's edge and cut off. So 765 is
        /// the page's real floor. The app states it rather than a smaller number it cannot enforce: a page
        /// minimum below what the content requires is a page that crops, and AppKit's answer to a split view
        /// requirement larger than its width is to break a constraint.
        static let pageMinWidth: CGFloat = 765
        static let navigationSidebarMinWidth: CGFloat = 200
        static let navigationSidebarIdealWidth: CGFloat = 220
        static let navigationSidebarMaxWidth: CGFloat = 300
        /// Widths of the Now Playing sidebar column. The reader can drag it between these, the way
        /// every other sidebar in the app behaves.
        static let nowPlayingSidebarMinWidth: CGFloat = 300
        static let nowPlayingSidebarIdealWidth: CGFloat = 380
        static let nowPlayingSidebarMaxWidth: CGFloat = 560
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
    /// What the page on screen wants in the window's toolbar. Owned by the window because the toolbar is
    /// the window's; the pages publish into it (`PageToolbarModel`), and the window hands whatever is
    /// current to the toolbar.
    @State private var pageToolbar = PageToolbarModel()
    /// Whether the page on screen has somewhere to go back to. Owned by the window for the same reason the
    /// page's toolbar controls are: the back control is a toolbar item of the window's own toolbar, and the
    /// pages publish into this (`PageNavigationModel`).
    @State private var pageNavigation = PageNavigationModel()
    @State private var miniPlayerWidth: CGFloat = Layout.miniPlayerDefaultWidth
    /// The pending window-chrome change for the fullscreen player (see `scheduleWindowChromeUpdate`).
    @State private var windowChromeTask: Task<Void, Never>?
    /// Whether the fullscreen player has ever been opened this launch.
    ///
    /// It is mounted from the first presentation on and then driven by attributes rather than being
    /// inserted and removed for each one — see the overlay in `body`. Nothing is built for a reader who
    /// never opens it.
    @State private var hasPresentedFullscreenNowPlaying = false

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
            if self.hasPresentedFullscreenNowPlaying, !self.playerService.isCurrentTrackPodcast {
                // Mounted once and then driven by attributes, never inserted and removed per presentation.
                //
                // A `.transition` makes the disappearance something that has to *complete* before the view
                // leaves the tree, and it runs in a transaction of its own that the reader's key or click
                // only starts: a removal still waiting to settle is a player that is still on screen with
                // its state already cleared — reported as "leaving fullscreen sometimes takes really
                // long", where the model has changed and the screen has not. Opacity carries no completion
                // step: it is applied with the next draw, and the state change never waits on an animation.
                // The presentation's own lifecycle is already driven by the flag (`startPresentation` /
                // `endPresentation` through `onChange`), so it never depended on this view being new.
                FullscreenNowPlayingView(client: self.client)
                    .opacity(self.playerService.showFullscreenNowPlaying ? 1 : 0)
                    .allowsHitTesting(self.playerService.showFullscreenNowPlaying)
                    .accessibilityHidden(!self.playerService.showFullscreenNowPlaying)
                    .animation(.easeInOut(duration: 0.22), value: self.playerService.showFullscreenNowPlaying)
                    .zIndex(10)
            }
        }
        .onAppear {
            self.hasPresentedFullscreenNowPlaying = self.playerService.showFullscreenNowPlaying
            self.scheduleWindowChromeUpdate(for: self.playerService.showFullscreenNowPlaying)
        }
        .onChange(of: self.playerService.showFullscreenNowPlaying) { _, isShown in
            // The flag reached the window. Logged because the whole exit is a sequence across two
            // objects — the player clears the flag, the window hears it and gives the toolbar back — and
            // "leaving the player does nothing" is one of them never arriving.
            let message = "Main window saw the fullscreen player presented=\(isShown)"
            DiagnosticsLogger.ui.notice("\(message, privacy: .public)")
            MainThreadStallReporter.shared.note("the window saw the fullscreen player = \(isShown)")
            if isShown { self.hasPresentedFullscreenNowPlaying = true }
            self.scheduleWindowChromeUpdate(for: isShown)
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
        // Diagnostic, and deliberately here rather than inside `hostsPlayerWebView`: that is read from
        // the view body, so it cannot log without logging a body evaluation. The gate is the thing a
        // "the mini player does nothing" report turns on, so its transitions are the evidence.
        .onChange(of: self.hostsPlayerWebView(showsPodcastFullscreen: showsPodcastFullscreen)) { _, hosts in
            let message = "Main window player layer hosted=\(hosts) "
                + "detached=\(self.playerService.isPlayerSurfaceDetachedToPanel) "
                + "pending=\(self.playerService.pendingPlayVideoId ?? "nil") "
                + "signedIn=\(self.authService.state.isLoggedIn)"
            DiagnosticsLogger.player.info("\(message, privacy: .public)")
        }
        // `pendingPlayVideoId` is what enables the player bar's mini player button, so its transitions
        // are the other half of "the button does nothing": an enabled control whose action never runs
        // and a control that is simply disabled look identical from outside, and only one of them is
        // about the click at all.
        .onChange(of: self.playerService.pendingPlayVideoId) { _, pending in
            let message = "Pending play video changed: \(pending ?? "nil") "
                + "miniPlayerButtonEnabled=\(pending != nil)"
            DiagnosticsLogger.player.info("\(message, privacy: .public)")
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
    ///
    /// It stands down while the surface is detached into the mini player panel
    /// (`PlayerService.isPlayerSurfaceDetachedToPanel`). There is one WebView and it can be in one
    /// window: the panel is the sole host while it is open, so hosting it here as well would have the
    /// two containers pull the same view back and forth — the surface would blank in whichever window
    /// lost, and a DRM stream does not survive being re-parented mid-song.
    private func hostsPlayerWebView(showsPodcastFullscreen: Bool) -> Bool {
        guard self.showsWebLayer, !showsPodcastFullscreen else { return false }
        guard !self.playerService.isPlayerSurfaceDetachedToPanel else { return false }
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
            viewportSize: CGSize(width: self.miniPlayerWidth, height: miniPlayerHeight),
            // The main window is the fallback host: it stands down the moment the surface is detached
            // into the mini player panel, so the two never both try to own the WebView.
            claimsSurface: !self.playerService.isPlayerSurfaceDetachedToPanel
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
            viewportSize: placesVideo ? slot.size : CGSize(width: 1, height: 1),
            claimsSurface: !self.playerService.isPlayerSurfaceDetachedToPanel
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

    /// The window's chrome change waits for the update that asked for it to finish.
    ///
    /// Hiding or restoring the toolbar is an AppKit layout of the titlebar, and it used to happen from
    /// inside the SwiftUI update that was adding or removing the fullscreen overlay. On the way out that is
    /// the update that has just torn the overlay down *and* is still inside the event that asked for it
    /// (the `Escape` key, or the close button's click), which is where leaving the player stopped
    /// responding — see `FullscreenNowPlayingView.closeFullscreenNowPlaying`. One runloop turn later the
    /// overlay is gone, that event has finished, and the window is free to lay its titlebar out.
    private func scheduleWindowChromeUpdate(for isFullscreenNowPlaying: Bool) {
        self.windowChromeTask?.cancel()
        self.windowChromeTask = Task { @MainActor in
            self.updateWindowTitleVisibility(for: isFullscreenNowPlaying)
        }
    }

    private func updateWindowTitleVisibility(for isFullscreenNowPlaying: Bool) {
        // Deliberately not `keyWindow`: with the detached mini player open the key window can be the
        // panel, and this would then hide the *panel's* title while leaving the main window's alone.
        // The main window is identified by its own autosave name, which is what the rest of the app
        // does (`AppDelegate.showMainWindowIfNeeded`).
        guard let window = NSApplication.shared.windows
            .first(where: { $0.frameAutosaveName == AppDelegate.mainWindowAutosaveName })
            ?? NSApplication.shared.windows.first(where: { $0.isMainWindow })
            ?? NSApplication.shared.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) })
        else {
            return
        }

        MainThreadStallReporter.shared.note("the window's chrome is being changed for the fullscreen player")
        window.titleVisibility = isFullscreenNowPlaying ? .hidden : .visible
        // The fullscreen Now Playing experience takes over the window, so the toolbar goes with it —
        // the same hidden state SwiftUI's `.toolbarVisibility(.hidden)` used to ask for.
        window.toolbar?.isVisible = !isFullscreenNowPlaying
        // The other end of the exit sequence (see the log in `body`): the toolbar and the title are back
        // and the window is what it was. The line after which nothing arrives is the step that stalled.
        let message = "Main window chrome for the fullscreen player: fullscreen=\(isFullscreenNowPlaying) "
            + "toolbarVisible=\(window.toolbar?.isVisible ?? false) "
            + "titleVisible=\(window.titleVisibility == .visible) key=\(window.isKeyWindow)"
        DiagnosticsLogger.ui.notice("\(message, privacy: .public)")
    }

    // MARK: - Main Content

    /// The window's three panes, laid out by AppKit's split view.
    ///
    /// The shell is AppKit's — one `NSSplitViewController` with a real sidebar item and a real inspector
    /// item — because those are what the window's toolbar derives its regions, and therefore its item
    /// positions, from. See `WindowShell`.
    private var mainContent: some View {
        WindowShell(
            sidebar: AnyView(self.sidebarPane),
            content: AnyView(self.contentPane),
            inspector: AnyView(self.inspectorPane),
            layout: self.shellLayout,
            showsInspector: self.playerService.isNowPlayingSidebarVisible,
            seedInspectorWidth: self.seedInspectorWidth,
            onInspectorCollapsedChange: { collapsed in
                // The reader moved the pane themselves — the toolbar's toggle, a drag, or a double click
                // on the divider — so the app's page state follows the pane rather than the other way
                // round. (`isApplyingState` in the shell keeps the app's own writes out of this.)
                withAnimation(AppAnimation.standard) {
                    if collapsed {
                        self.playerService.closeNowPlayingSidebar()
                    } else {
                        self.playerService.setNowPlayingSidebarPage(.overview)
                    }
                }
            },
            toolbar: WindowToolbarItems(
                tracksColumn: self.playerService.isNowPlayingSidebarVisible,
                showsAI: FoundationModelsService.shared.isAvailable,
                // Shown whenever the column design is on, open or closed: the toggle is the toolbar's
                // own item in both states (see `WindowToolbarItems`), so it never has to move into the
                // column — and the column's top band stays the artwork's.
                showsNowPlayingToggle: self.playerService.isNowPlayingSidebarEnabled,
                canGoBack: self.pageNavigation.canGoBack,
                pageControls: self.pageToolbar.contribution,
                onBack: { self.pageNavigation.goBack() },
                onAI: { self.isCommandBarPresented = true }
            )
        )
        // The window's minimum, stated once and in the same terms the shell enforces it in: the panes' own
        // minimums plus the dividers, never below the app's long-standing floor. `WindowShellController`
        // writes the same number to the window, so the two agree rather than fighting — and a window
        // narrower than this is one at which a pane would have to give up its minimum and crop.
        .frame(
            minWidth: self.shellLayout.minimumWindowWidth(
                tracksColumn: self.playerService.isNowPlayingSidebarVisible
            ),
            minHeight: Layout.minimumContentHeight
        )
        // The shell is the window: its panes are what the window draws, so they own the space under the
        // titlebar. Each pane then re-insets its own content by AppKit's window safe area (`ShellPane`'s
        // children lay out below the toolbar) while the panes that *are* a backdrop — the navigation
        // sidebar's material and the Now Playing column's artwork — run to the window's top edge, which is
        // what makes the titlebar read as part of the sidebar rather than as a band above it.
        .ignoresSafeArea(.container, edges: .top)
    }

    /// The navigation sidebar, on AppKit's own sidebar surface.
    ///
    /// `NavigationSplitView` used to supply this surface. The window shell replaced that split view, so
    /// the pane supplies it again (`SidebarMaterialPane`: the `.sidebar` material at `.behindWindow`, with
    /// the sidebar's SwiftUI inside it).
    ///
    /// Hosting it there costs one thing, and it is paid in `Sidebar`: the sidebar's content resolves its
    /// colours in a **vibrant** appearance, where `labelColor` is a lower-alpha colour than the plain one
    /// (black @ 0.70 against 0.85) — so the nav rows state a literal colour rather than `.primary`.
    /// Measured, and written up on `EmphasizedMaterialView`.
    private var sidebarPane: some View {
        SidebarMaterialPane {
            Sidebar(selection: self.$navigationSelection)
                .environment(self.libraryViewModel)
        }
        // The material is the pane's surface, so it reaches the window's top edge; the sidebar's own
        // content inside it still starts below the toolbar.
        .ignoresSafeArea(.container, edges: .top)
    }


    /// The page, plus the classic lyrics/queue panels.
    ///
    /// The panels are overlays of the *content pane*, not of the window: they belong to the page, and
    /// over the window they would sit on top of the Now Playing column.
    private var contentPane: some View {
        ZStack(alignment: .trailing) {
            self.detailView(for: self.navigationSelection, client: self.client)

            // Classic lyrics/queue panels, floating over the content (mutually exclusive).
            self.classicSidebarOverlay(client: self.client)
        }
        // The page is a surface of its own. The window is a clear sheet so the navigation sidebar's
        // material can blur the desktop (`SidebarMaterialPane`), which means *every* other pane has to
        // paint its own opaque background or the desktop shows through it. The background bleeds up under
        // the toolbar for the same reason the sidebar's material does: without that the titlebar band over
        // the page would be the one strip of the window with nothing behind it.
        .background {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea(edges: .top)
        }
        // The pages publish their toolbar controls to the window through this (see `PageToolbarModel`),
        // and their navigation stacks state whether they can be popped (`PageNavigationModel`).
        .environment(self.pageToolbar)
        .environment(self.pageNavigation)
    }

    /// The Now Playing sidebar.
    ///
    /// Unmounted rather than merely collapsed while the column is closed: appearing and disappearing is
    /// what starts and stops its lyrics polling and canvas loading, and a collapsed pane still holds its
    /// view.
    @ViewBuilder
    private var inspectorPane: some View {
        if self.playerService.isNowPlayingSidebarVisible {
            ShellPane { size, topInset in
                NowPlayingSidebarView(
                    columnWidth: size.width,
                    columnHeight: size.height,
                    topInset: topInset
                )
            }
        } else {
            Color.clear
        }
    }

    /// The column bounds AppKit's split view items enforce.
    ///
    /// The page's own minimum is stated as what its content actually needs (`pageMinWidth`), and the
    /// window's is the panes' sum — so opening the Now Playing column asks for a window wide enough to hold
    /// it instead of squeezing the page below its floor. See `WindowShellLayout`.
    private var shellLayout: WindowShellLayout {
        WindowShellLayout(
            minSidebarWidth: Layout.navigationSidebarMinWidth,
            maxSidebarWidth: Layout.navigationSidebarMaxWidth,
            minContentWidth: Layout.pageMinWidth,
            minWindowWidth: Layout.detailMinWidth,
            minInspectorWidth: Layout.nowPlayingSidebarMinWidth,
            maxInspectorWidth: Layout.nowPlayingSidebarMaxWidth
        )
    }

    /// The width the Now Playing sidebar opens at the first time this build runs.
    ///
    /// AppKit's autosave owns the divider from then on, and the app never writes a width on a drag —
    /// which is what removes the whole class of "the stored width fights the divider" bugs the column
    /// used to have. The stored setting is read here once, as the value to start from.
    private var seedInspectorWidth: CGFloat {
        let stored = CGFloat(self.settings.nowPlayingSidebarWidth)
        guard stored.isFinite, stored > 0 else { return Layout.nowPlayingSidebarIdealWidth }
        // A stored width is a user-editable default, so it is put through the column's own bounds before it
        // reaches the split view. `availableWidth: 0` states that the app has no window knowledge here —
        // the divider's own limits are the split items' (see `WindowShellLayout`), which is what makes this
        // clamp the column's bounds and nothing else.
        return NowPlayingSidebarColumnGeometry(
            availableWidth: 0,
            detailMinWidth: 0,
            handleWidth: 0,
            minWidth: Layout.nowPlayingSidebarMinWidth,
            maxWidth: Layout.nowPlayingSidebarMaxWidth,
            floorWidth: Layout.nowPlayingSidebarMinWidth
        ).effective(desired: stored)
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
                DetailNavigationStack(id: "playlist-\(playlist.id)") { path in
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
                DetailNavigationStack(id: "likedMusic") { path in
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
