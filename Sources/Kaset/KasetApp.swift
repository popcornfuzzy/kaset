import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var searchFocusTrigger: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
    @Entry var navigationSelection: Binding<SidebarSelection?> = .constant(nil)
}

extension EnvironmentValues {
    @Entry var showCommandBar: Binding<Bool> = .constant(false)
}

extension EnvironmentValues {
    @Entry var showWhatsNew: Binding<Bool> = .constant(false)
}

// MARK: - AppWindowState

/// The window's own UI state: the navigation selection, and the one-shot triggers the menus set.
///
/// An `@Observable` object rather than `@State`, because the app's main window is AppKit's
/// (`AppDelegate.installMainWindow`) and its root view is therefore built in `KasetApp.init` — the one
/// place SwiftUI cannot hand out state. There a `@State` read produces a **constant** binding (the
/// navigation sidebar's selection stopped responding) and a **new instance on every read** for a value.
/// The menu commands write these properties directly; the window's views read them through bindings built
/// from this object (`KasetApp.binding(_:)`), which observe it the same way any other observed property is
/// observed.
@available(macOS 26.0, *)
@MainActor
@Observable
final class AppWindowState {
    /// Current navigation selection for keyboard navigation.
    var navigationSelection: SidebarSelection? = .navigation(SettingsManager.shared.launchNavigationItem)

    /// Triggers search field focus when set to true.
    var searchFocusTrigger = false

    /// Whether the command bar is visible.
    var showCommandBar = false

    /// Whether the "What's New" sheet should be shown.
    var showWhatsNew = false
}

// MARK: - KasetApp

/// Main entry point for the Kaset macOS application.
@available(macOS 26.0, *)
@main
struct KasetApp: App {
    /// App delegate for lifecycle management (background playback).
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// The app's services.
    ///
    /// Plain stored properties rather than `@State`, because the app's main window is AppKit's
    /// (`AppDelegate.installMainWindow`): its root view is built in `init`, and a `@State` read there is
    /// not a read. SwiftUI reports
    /// *"Accessing State's value outside of being installed on a View"*, hands back a **constant binding**
    /// from the projection — which is why the navigation sidebar's selection stopped responding — and
    /// creates a **new instance each time** for a value, which is why the window was driven by services
    /// that were not the app's. None of these are ever replaced after `init`, which is what makes `let`
    /// the honest declaration for them as well.
    let authService: AuthService
    let webKitManager: WebKitManager
    let playerService: PlayerService
    let sharedClient: any YTMusicClientProtocol
    let notificationService: NotificationService
    let updaterService = UpdaterService()
    let favoritesManager = FavoritesManager.shared
    let likeStatusManager = SongLikeStatusManager.shared
    let accountService: AccountService
    let scrobblingCoordinator: ScrobblingCoordinator
    let syncedLyricsService = SyncedLyricsService(cacheStore: LyricsCacheStore())
    let podcastTranscriptService: PodcastTranscriptService
    let canvasService = CanvasService()
    let castService = CastService()

    /// The window's own UI state — the navigation selection and the one-shot triggers the menus set —
    /// as an `@Observable` object, for the same reason the services above are not `@State`: the root view
    /// is built in `init`, so its bindings have to be real bindings built from something that exists
    /// before SwiftUI installs a view.
    let ui = AppWindowState()

    init() {
        let auth = AuthService()
        let webkit = WebKitManager.shared
        let player = PlayerService()

        // Use mock client in UI test mode, real client otherwise
        let realClient = YTMusicClient(authService: auth, webKitManager: webkit)
        let client: YTMusicClientProtocol = if UITestConfig.isUITestMode {
            MockUITestYTMusicClient()
        } else {
            realClient
        }

        // Wire up dependencies
        player.setYTMusicClient(client)
        SongLikeStatusManager.shared.setClient(client)

        // Set shared instance for AppleScript access
        PlayerService.shared = player

        // Create account service
        let account = AccountService(ytMusicClient: client, authService: auth)

        // Wire up brand account provider so API requests use the correct account
        realClient.brandIdProvider = { [weak account] in
            account?.currentBrandId
        }

        // Create scrobbling coordinator
        let lastFMService = LastFMService(credentialStore: KeychainCredentialStore())
        let scrobblingCoordinator = ScrobblingCoordinator(
            playerService: player,
            services: [lastFMService]
        )
        scrobblingCoordinator.restoreAuthState()
        scrobblingCoordinator.startMonitoring()

        self.authService = auth
        self.webKitManager = webkit
        self.playerService = player
        self.sharedClient = client
        self.notificationService = NotificationService(playerService: player)
        self.accountService = account
        self.scrobblingCoordinator = scrobblingCoordinator
        self.podcastTranscriptService = PodcastTranscriptService(client: client)

        // Wire up PlayerService to AppDelegate immediately (not in onAppear)
        // This ensures playerService is available for lifecycle events like queue restoration
        self.appDelegate.playerService = player
        self.appDelegate.authService = auth
        // The main window is AppKit's (`AppDelegate.installMainWindow`), so what the `Window` scene used
        // to host is built here and handed over. Everything it needs is a plain stored property by now,
        // so nothing here is a `@State` read.
        self.appDelegate.rootView = AnyView(self.makeRootView())
        // The detached mini player panel is a window the app owns too, so its content is built here
        // for the same reason the main window's is: the services exist by now, and its SwiftUI needs
        // them. Built lazily — the panel is only created the first time it is opened.
        // The provider captures the two services the panel needs rather than `self`: `KasetApp` is a
        // value type, so there is no instance to hold weakly, and these are the only things the
        // panel's view reads.
        let panelPlayerService = player
        let panelWebKitManager = webkit
        self.appDelegate.miniPlayerPanelContentProvider = {
            NSHostingController(
                rootView: MiniPlayerPanel()
                    .environment(panelPlayerService)
                    .environment(panelWebKitManager)
                    .frame(minWidth: MiniPlayerPanelLayout.minimumWidth)
            )
        }

        if UITestConfig.isUITestMode {
            // Leaves a trace the UI test script checks, since the log's info-level entries are not
            // flushed in time to be read back at the end of a run (see `UITestConfig`).
            UITestConfig.markUITestModeSeen()
            DiagnosticsLogger.ui.info("App launched in UI Test mode")
        }
    }

    /// A real binding to one of the window's UI-state properties.
    ///
    /// `AppWindowState` is an `@Observable` class, so a binding built here observes it like any other: the
    /// views that read through it re-render when the property changes, and writes reach the menus.
    private func binding<T>(_ keyPath: ReferenceWritableKeyPath<AppWindowState, T>) -> Binding<T> {
        Binding(
            get: { self.ui[keyPath: keyPath] },
            set: { self.ui[keyPath: keyPath] = $0 }
        )
    }

    /// The view the app's main window hosts.
    ///
    /// This is what the `Window` scene used to declare. The window is AppKit's now
    /// (`AppDelegate.installMainWindow`), because a SwiftUI-owned window cannot give its toolbar to the
    /// app, so the view is built here and handed to the delegate in `init`.
    @MainActor
    private func makeRootView() -> some View {
        MainWindow(navigationSelection: self.binding(\.navigationSelection), client: self.sharedClient)
            .environment(self.authService)
            .environment(self.webKitManager)
            .environment(self.playerService)
            .environment(self.favoritesManager)
            .environment(self.likeStatusManager)
            .environment(self.accountService)
            .environment(self.scrobblingCoordinator)
            .environment(self.syncedLyricsService)
            .environment(self.podcastTranscriptService)
            .environment(self.canvasService)
            .environment(self.castService)
            .environment(\.searchFocusTrigger, self.binding(\.searchFocusTrigger))
            .environment(\.navigationSelection, self.binding(\.navigationSelection))
            .environment(\.showCommandBar, self.binding(\.showCommandBar))
            .environment(\.showWhatsNew, self.binding(\.showWhatsNew))
            .onAppear {
                // Wire up PlayerService to AppDelegate for dock menu and AppleScript actions
                // This runs synchronously so AppleScript commands can access playerService immediately
                self.appDelegate.playerService = self.playerService
                // Reference notificationService to keep SwiftUI from deallocating it
                _ = self.notificationService
            }
            .task {
                // Split any legacy single-file lyrics cache into per-song files.
                // Kicked off without awaiting so it never delays first paint or auth.
                Task {
                    await self.syncedLyricsService.migrateLegacyCacheIfNeeded()
                }

                // Check if user is already logged in from previous session
                await self.authService.checkLoginStatus()

                // Fetch accounts after login check (for account switcher)
                await self.accountService.fetchAccounts()

                // Warm up Foundation Models in background
                await FoundationModelsService.shared.warmup()
            }
    }

    var body: some Scene {
        // The app's main window is deliberately **not** a scene: it is an `NSWindow` the delegate creates
        // (`AppDelegate.installMainWindow`), because a SwiftUI-owned window cannot hand its toolbar to the
        // app — SwiftUI's window controller owns that toolbar, rewrites its items from its own content, and
        // keeps key-value observations on it. With no `Window` scene there is no such controller, so the
        // window's toolbar belongs to the app outright and the tracking separators that bound the page's
        // controls to the Now Playing column can be the app's own.
        Settings {
            SettingsView()
                .environment(self.authService)
                .environment(self.updaterService)
                .environment(self.scrobblingCoordinator)
                .environment(self.syncedLyricsService)
                .environment(self.podcastTranscriptService)
                .environment(self.canvasService)
        }
        .commands {
            // Check for Updates command in app menu
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    self.updaterService.checkForUpdates()
                }
                .disabled(!self.updaterService.canCheckForUpdates)
            }

            // Playback commands
            CommandMenu("Playback") {
                // Play/Pause - Space
                Button(self.playerService.isPlaying ? "Pause" : "Play") {
                    Task {
                        await self.playerService.playPause()
                    }
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(self.playerService.currentTrack == nil && self.playerService.pendingPlayVideoId == nil)

                Divider()

                // Next Track - ⌘→
                Button("Next") {
                    Task {
                        await self.playerService.next()
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(self.playerService.currentEpisode != nil)

                // Previous Track - ⌘←
                Button("Previous") {
                    Task {
                        await self.playerService.previous()
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(self.playerService.currentEpisode != nil)

                Divider()

                // Volume Up - ⌘↑
                Button("Volume Up") {
                    Task {
                        await self.playerService.setVolume(min(1.0, self.playerService.volume + 0.1))
                    }
                }
                .keyboardShortcut(.upArrow, modifiers: .command)

                // Volume Down - ⌘↓
                Button("Volume Down") {
                    Task {
                        await self.playerService.setVolume(max(0.0, self.playerService.volume - 0.1))
                    }
                }
                .keyboardShortcut(.downArrow, modifiers: .command)

                // Mute
                Button(self.playerService.isMuted ? "Unmute" : "Mute") {
                    Task {
                        await self.playerService.toggleMute()
                    }
                }

                Divider()

                // Shuffle - ⌘S
                Button(self.playerService.shuffleEnabled ? "Shuffle Off" : "Shuffle On") {
                    self.playerService.toggleShuffle()
                }
                .keyboardShortcut("s", modifiers: .command)

                // Repeat - ⌘R
                Button(self.repeatModeLabel) {
                    self.playerService.cycleRepeatMode()
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                // Lyrics - ⌘L
                Button(self.lyricsCommandTitle) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if self.playerService.isNowPlayingSidebarEnabled {
                            self.playerService.toggleNowPlayingSidebar(page: .lyrics)
                        } else {
                            self.playerService.showLyrics.toggle()
                        }
                    }
                }
                .keyboardShortcut("l", modifiers: .command)
            }

            // Navigation commands - replace default sidebar toggle
            CommandGroup(replacing: .sidebar) {
                // Home - ⌘1
                Button("Home") {
                    self.ui.navigationSelection = .navigation(.home)
                }
                .keyboardShortcut("1", modifiers: .command)

                // Explore - ⌘2
                Button("Explore") {
                    self.ui.navigationSelection = .navigation(.explore)
                }
                .keyboardShortcut("2", modifiers: .command)

                // Library - ⌘3
                Button("Library") {
                    self.ui.navigationSelection = .navigation(.library)
                }
                .keyboardShortcut("3", modifiers: .command)

                Divider()

                // Search - ⌘F
                Button("Search") {
                    self.ui.navigationSelection = .navigation(.search)
                    // Trigger focus after a brief delay to allow view to appear
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        self.ui.searchFocusTrigger = true
                    }
                }
                .keyboardShortcut("f", modifiers: .command)

                // Command Bar - ⌘K
                Button("Command Bar") {
                    self.ui.showCommandBar = true
                }
                .keyboardShortcut("k", modifiers: .command)
            }

            // Window menu - show main window
            CommandGroup(after: .windowArrangement) {
                Button("Kaset") {
                    self.showMainWindow()
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            // Window menu - the detached mini player.
            //
            // It belongs in the Window menu because it *is* a window, and because that is where a
            // reader looks for one they have lost. It is listed unconditionally, not only while the
            // mini player window setting is on: a reader who turns the setting off while the panel is
            // open still needs a way to close it.
            CommandGroup(after: .windowList) {
                Button(self.isMiniPlayerPanelVisible ? "Close Mini Player" : "Mini Player") {
                    self.toggleMiniPlayerPanel()
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
            }

            // Help menu - What's New
            CommandGroup(after: .appInfo) {
                Divider()
                Button("What's New in Kaset") {
                    self.ui.showWhatsNew = true
                }
            }
        }
    }

    /// Whether the detached mini player panel is on screen.
    private var isMiniPlayerPanelVisible: Bool {
        (NSApplication.shared.delegate as? AppDelegate)?.isMiniPlayerPanelVisible ?? false
    }

    /// Opens or closes the detached mini player panel.
    ///
    /// The one place the menu and the player bar's button agree: both ask the delegate, which owns
    /// the window and moves the player surface with it.
    private func toggleMiniPlayerPanel() {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
        if self.isMiniPlayerPanelVisible {
            appDelegate.closeMiniPlayerPanel()
        } else {
            appDelegate.showMiniPlayerPanel()
        }
    }

    /// Shows the main window.
    private func showMainWindow() {
        // Find and show the main window
        for window in NSApplication.shared.windows where window.frameAutosaveName == AppDelegate.mainWindowAutosaveName {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        // Fallback: find any main-capable window
        for window in NSApplication.shared.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
    }

    /// Label for repeat mode menu item.
    private var repeatModeLabel: String {
        switch self.playerService.repeatMode {
        case .off:
            "Repeat All"
        case .all:
            "Repeat One"
        case .one:
            "Repeat Off"
        }
    }

    /// Title of the ⌘L command. The key opens the lyrics either way; with the Now Playing sidebar
    /// enabled it drives that panel's lyric page instead of the classic lyrics panel.
    private var lyricsCommandTitle: String {
        let isShowing = self.playerService.isLyricsPanelActive
        return isShowing ? String(localized: "Hide Lyrics") : String(localized: "Show Lyrics")
    }

}

// MARK: - SettingsView

/// Main settings view with tabbed navigation.
@available(macOS 26.0, *)
struct SettingsView: View {
    @Environment(UpdaterService.self) private var updaterService
    @Environment(ScrobblingCoordinator.self) private var scrobblingCoordinator

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            LyricsSettingsView()
                .tabItem {
                    Label("Lyrics", systemImage: "music.note")
                }

            IntelligenceSettingsView()
                .tabItem {
                    Label("Intelligence", systemImage: "sparkles")
                }

            ScrobblingSettingsView()
                .environment(self.scrobblingCoordinator)
                .tabItem {
                    Label {
                        Text("Scrobbling")
                    } icon: {
                        Image("LastFM", bundle: PackageResourceLookup.bundle(forImageNamed: "LastFM"))
                            .resizable()
                            .scaledToFit()
                            .frame(height: 12)
                            .accessibilityHidden(true)
                    }
                }

            AboutSettingsView(updaterService: self.updaterService)
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 450, height: 400)
    }
}
