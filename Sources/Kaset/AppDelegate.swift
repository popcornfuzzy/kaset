import AppKit
import SwiftUI
import UserNotifications

// MARK: - AppDelegate

/// App delegate to control application lifecycle behavior.
/// Keeps the app running when windows are closed so audio playback continues.
///
/// It also owns the app's main window (see `installMainWindow()`): the window is AppKit's so that the
/// window toolbar's item list can be the app's, which it cannot be while SwiftUI owns the window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Reference to the PlayerService for dock menu actions.
    /// Set by KasetApp after initialization.
    weak var playerService: PlayerService?

    /// What the app's main window hosts: `MainWindow` with its whole environment, built by `KasetApp`.
    ///
    /// The window is AppKit's, so the view that used to be the `Window` scene's content is handed here
    /// instead of being declared in a scene.
    var rootView: AnyView?

    /// The `AuthService` the URL handler needs. `KasetApp` is the owner; this is a back reference only.
    weak var authService: AuthService?

    /// Reference to the main window for reliable reopen behavior.
    /// Using strong reference to prevent deallocation when window is hidden.
    private var mainWindow: NSWindow?

    /// The detached mini player's window, created the first time it is opened.
    ///
    /// Owned here because it is a *window*, and because it is what moves the shared player surface
    /// between the two windows: the panel is created with the app's services, handed the surface when
    /// it opens, and takes the surface back out of it when it closes.
    private var miniPlayerPanelController: MiniPlayerPanelController?

    /// Builds the mini player panel's content with the app's environment. `KasetApp` sets this in
    /// `init`, because the services are the app's and this delegate cannot reach them otherwise.
    @MainActor
    var miniPlayerPanelContentProvider: (() -> NSViewController)?

    func applicationDidFinishLaunching(_: Notification) {
        // Set up notification center delegate to show notifications in foreground
        UNUserNotificationCenter.current().delegate = self

        // The main window is the app's, so it is created here rather than by a SwiftUI scene.
        self.installMainWindow()

        // In UI test mode, activate the app to bring window to foreground
        if UITestConfig.isUITestMode {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        // Set up window delegate to intercept close and hide instead
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            self.setupWindowDelegate()
        }

        // Register for system sleep/wake notifications
        self.registerForSleepWakeNotifications()

        // Focus and click tracing. A control that does nothing and a sidebar that looks inactive have
        // one shared set of causes — whether the window is actually key, and whether the click reaches
        // the app at all — and neither is visible from a view's own state.
        self.installUITrace()

        // Measures a main thread that stops answering, from a thread that is still running — the one
        // thing the app cannot log about itself. See `MainThreadStallReporter`.
        MainThreadStallReporter.shared.start()

        // Restore saved queue if available
        self.playerService?.restoreQueueFromPersistence()
    }

    // MARK: - Focus & click tracing

    /// The monitor that reports every click the app receives, so a control that "does nothing" can be
    /// told apart from a click that never arrived.
    private var clickMonitor: Any?
    private var isUITraceInstalled = false

    /// Reports focus changes and every left click, with where the click landed.
    ///
    /// This is deliberately at the application level rather than on a view: a SwiftUI control's action
    /// only runs if the event was delivered *and* the control was enabled, so when a button is inert the
    /// two things to rule out are an event that never reached the app (a non-key window swallows the
    /// first click) and an event that landed on something else entirely (an overlay above the control).
    /// AppKit can answer both; the view cannot.
    private func installUITrace() {
        guard !self.isUITraceInstalled else { return }
        self.isUITraceInstalled = true

        let center = NotificationCenter.default
        let focusEvents: [(Notification.Name, String)] = [
            (NSApplication.didBecomeActiveNotification, "app became active"),
            (NSApplication.didResignActiveNotification, "app resigned active"),
            (NSWindow.didBecomeKeyNotification, "window became key"),
            (NSWindow.didResignKeyNotification, "window resigned key"),
        ]
        for (name, description) in focusEvents {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.logFocus(description) }
            }
        }

        self.clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.logClick(event) }
            return event
        }

        self.logFocus("trace installed")
    }

    private func logFocus(_ what: String) {
        let keyWindow = NSApp.keyWindow
        let message = "Focus: \(what) appActive=\(NSApp.isActive) "
            + "keyWindow=\(keyWindow.map { String(describing: type(of: $0)) } ?? "nil") "
            + "keyTitle=\(keyWindow?.title ?? "-") "
            + "mainIsKey=\(self.mainWindow?.isKeyWindow ?? false) "
            + "mainIsMain=\(self.mainWindow?.isMainWindow ?? false) "
            + "windows=\(NSApp.windows.count)"
        DiagnosticsLogger.ui.info("\(message, privacy: .public)")
    }

    private func logClick(_ event: NSEvent) {
        let window = event.window
        let location = event.locationInWindow
        let hitView = window?.contentView?.hitTest(location)
        let message = "Click: window=\(window.map { String(describing: type(of: $0)) } ?? "nil") "
            + "title=\(window?.title ?? "-") "
            + "at=\(Int(location.x)),\(Int(location.y)) "
            + "hit=\(hitView.map { String(describing: type(of: $0)) } ?? "nil") "
            + "appActive=\(NSApp.isActive) windowIsKey=\(window?.isKeyWindow ?? false)"
        DiagnosticsLogger.ui.info("\(message, privacy: .public)")
    }

    // MARK: - Main Window

    /// Creates the app's main window: an AppKit `NSWindow` hosting `MainWindow`, with the app's toolbar.
    ///
    /// ## Why the window is AppKit's
    ///
    /// The window's toolbar carries what a macOS window's toolbar has to carry here: the sidebar toggle,
    /// the Now Playing toggle, the page's own search/sort/refresh, and AppKit's two **tracking
    /// separators** — the items that sit on a split view's dividers and bound the region to their left,
    /// which is what keeps the page's controls off the Now Playing column
    /// ([ADR-0030](../../docs/adr/0030-appkit-window-shell.md)).
    ///
    /// That item list can only be the app's if the toolbar *object* is the app's too, and SwiftUI's window
    /// controller will not allow it: it owns the toolbar it installs for the window, rewrites that
    /// toolbar's items from its own content on every constraint pass, and — worse — keeps key-value
    /// observations on the object, so replacing it makes its next `AppKitWindowController
    /// .updateToolbarIfNeeded` (which runs from `NSHostingView.updateConstraints`, inside a display-cycle
    /// constraint pass) remove an observer that is not registered on the toolbar it now finds. That raises
    /// `NSRangeException`, and AppKit turns an exception escaping a constraint pass into
    /// `+[NSApplication _crashOnException:]` — the `SIGTRAP` crash this replaces.
    ///
    /// An `NSWindow` the app makes itself has no SwiftUI window controller at all. Nothing re-writes the
    /// toolbar, nothing observes it, and the shell's `WindowToolbarController` owns it outright.
    private func installMainWindow() {
        guard let rootView = self.rootView else {
            DiagnosticsLogger.app.error("No root view was handed to AppDelegate; the main window was not created")
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Kaset"
        // The window shell's chrome (`WindowShellController.applyWindowChrome`): the panes are the window,
        // so their backdrops run to the top edge under a titlebar that is not drawn.
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // The window is not a surface of its own: it is a clear sheet the panes draw on.
        //
        // That is what makes the navigation sidebar's material a real macOS sidebar —
        // `NSVisualEffectView` with `blendingMode = .behindWindow` blurs what is *behind the window*, so
        // the column samples the desktop the way Finder's and Mail's do. While the window draws its own
        // opaque background, the same effect view has nothing but that background to composite against
        // and the sidebar reads as a flat grey sheet laid over the window — the exact "grey layer" this
        // removes. The page and the Now Playing column paint their own opaque surfaces (see
        // `MainWindow.contentPane` and `NowPlayingSidebarBackground`), so only the sidebar is translucent.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentMinSize = NSSize(width: 900, height: 600)
        // The delegate hides the window on close instead of closing it; a programmatically created
        // window is released on close by default, which would leave the shell's controller without a view.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: rootView)
        window.setContentSize(NSSize(width: 1280, height: 820))
        // Restores the reader's frame and position when there is one to restore; otherwise the window
        // opens centred.
        if !window.setFrameAutosaveName(Self.mainWindowAutosaveName) {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)

        self.mainWindow = window
    }

    /// The name the main window's frame is persisted under. Also what `AppDelegate` and `KasetApp`
    /// identify it by when they need to find it.
    static let mainWindowAutosaveName = "KasetMainWindow"

    // MARK: - Mini Player Panel

    /// Opens the detached mini player, moving the shared player surface into it.
    ///
    /// The order matters: the surface is handed to the panel *before* the panel is shown, so the
    /// WebView is already being hosted by the panel's view when it appears. Showing first would let a
    /// frame of the main window's layer draw the surface it no longer owns.
    func showMiniPlayerPanel() {
        guard let playerService else {
            DiagnosticsLogger.player.error("Mini player panel requested before PlayerService was wired")
            return
        }

        let controller = self.miniPlayerPanelController ?? self.makeMiniPlayerPanelController()
        guard let controller else {
            DiagnosticsLogger.player.error("Mini player panel: no controller, the panel was not shown")
            return
        }

        playerService.setPlayerSurfaceHost(.miniPlayerPanel)
        controller.show()
        let message = "Mini player panel requested: visible=\(controller.isPanelVisible) "
            + "surfaceHost=\(playerService.playerSurfaceHost.rawValue) "
            + "pending=\(playerService.pendingPlayVideoId ?? "nil")"
        DiagnosticsLogger.player.info("\(message, privacy: .public)")
    }

    /// Closes the detached mini player, returning the shared player surface to the main window.
    func closeMiniPlayerPanel() {
        guard let controller = self.miniPlayerPanelController else { return }
        controller.dismiss()
        // The close may have been declined (a panel that was never open); the surface returns either
        // way, because the app's state — not the window's — is what decides who hosts it.
        self.playerService?.setPlayerSurfaceHost(.mainWindow)
        let message = "Mini player panel closed: visible=\(controller.isPanelVisible)"
        DiagnosticsLogger.player.info("\(message, privacy: .public)")
    }

    /// Whether the detached mini player is currently on screen.
    var isMiniPlayerPanelVisible: Bool {
        self.miniPlayerPanelController?.isPanelVisible ?? false
    }

    private func makeMiniPlayerPanelController() -> MiniPlayerPanelController? {
        guard let playerService, let contentProvider = self.miniPlayerPanelContentProvider else {
            DiagnosticsLogger.player.error("No panel content was handed to AppDelegate; the mini player panel was not created")
            return nil
        }

        let controller = MiniPlayerPanelController(
            playerService: playerService,
            settings: SettingsManager.shared,
            contentViewController: contentProvider()
        )
        // A close the reader performs takes the surface back. This is the only path by which the
        // surface returns from the panel without the app asking for it, and it is why the panel can
        // be closed with its own close button without stranding the video.
        controller.onClose = { [weak self] in
            self?.playerService?.setPlayerSurfaceHost(.mainWindow)
        }
        self.miniPlayerPanelController = controller
        return controller
    }

    // MARK: - URL Handling

    /// Handles a URL the app was opened with (its custom scheme).
    ///
    /// This used to be the `Window` scene's `.onOpenURL`; with the window AppKit's, the delegate is the
    /// app's URL entry point.
    func application(_: NSApplication, open urls: [URL]) {
        for url in urls {
            self.handleIncomingURL(url)
        }
    }

    private func handleIncomingURL(_ url: URL) {
        DiagnosticsLogger.app.info("Received URL: \(url.absoluteString)")

        guard let content = URLHandler.parse(url) else {
            DiagnosticsLogger.app.warning("Unrecognized URL format: \(url.absoluteString)")
            return
        }

        guard self.authService?.state.isLoggedIn == true else {
            DiagnosticsLogger.app.info("Not logged in, ignoring URL")
            return
        }

        switch content {
        case let .song(videoId):
            DiagnosticsLogger.app.info("Playing song from URL: \(videoId)")
            let song = Song(id: videoId, title: "Loading...", artists: [], videoId: videoId)
            Task {
                await self.playerService?.play(song: song)
            }

        case .playlist, .album, .artist:
            // Only song playback is supported via URL scheme
            DiagnosticsLogger.app.info("URL scheme only supports song playback")
        }
    }

    func applicationWillTerminate(_: Notification) {
        // Save queue for persistence on next launch
        self.playerService?.saveQueueForPersistence()
        DiagnosticsLogger.player.info("Application will terminate - saved queue for persistence")
    }

    /// Registers for system sleep and wake notifications to handle playback appropriately.
    private func registerForSleepWakeNotifications() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        notificationCenter.addObserver(
            self,
            selector: #selector(self.systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        notificationCenter.addObserver(
            self,
            selector: #selector(self.systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    /// Tracks whether audio was playing before system sleep (for resume on wake).
    private var wasPlayingBeforeSleep: Bool = false

    @objc private func systemWillSleep(_: Notification) {
        // Remember playback state and pause before sleep
        self.wasPlayingBeforeSleep = self.playerService?.isPlaying ?? false
        if self.wasPlayingBeforeSleep {
            DiagnosticsLogger.player.info("System going to sleep, pausing playback")
            SingletonPlayerWebView.shared.pause()
        }
    }

    @objc private func systemDidWake(_: Notification) {
        // Optionally resume playback after wake if it was playing before sleep
        // Note: We don't auto-resume by default as it could be surprising
        // Just log the wake event for now
        DiagnosticsLogger.player.info("System woke from sleep, wasPlayingBeforeSleep: \(self.wasPlayingBeforeSleep)")
    }

    func applicationDidBecomeActive(_: Notification) {
        // When app becomes active (e.g., dock icon clicked), ensure main window is visible.
        self.showMainWindowIfNeeded()
    }

    private func setupWindowDelegate() {
        for window in NSApplication.shared.windows where window.canBecomeMain {
            window.delegate = self
            // Enable automatic window frame persistence using autosave name
            //
            // Only this window may wear it. The name is how the app finds its main window —
            // `AppDelegate.showMainWindowIfNeeded`, `KasetApp.showMainWindow`,
            // `MainWindow.updateWindowTitleVisibility`, the fullscreen player's host lookup and the
            // mini player panel's placement all resolve it by name — so a second window carrying it is
            // not merely remembered with the wrong frame: it makes *every* one of those lookups a
            // coin-flip between two windows. A window that is not the app's main window keeps its own
            // name (or none).
            if window === self.mainWindow, window.frameAutosaveName.isEmpty {
                window.setFrameAutosaveName(Self.mainWindowAutosaveName)
            }
            // The app creates the main window itself now, so this only fills the gap for a window that
            // appeared another way (a `Settings` window, say) — it never replaces the app's own reference.
            if self.mainWindow == nil {
                self.mainWindow = window
            }
        }
    }

    // MARK: - Dock Menu

    func applicationDockMenu(_: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let playPauseItem = NSMenuItem(
            title: "Play/Pause",
            action: #selector(dockMenuPlayPause),
            keyEquivalent: ""
        )
        playPauseItem.target = self
        menu.addItem(playPauseItem)

        let nextItem = NSMenuItem(
            title: "Next Track",
            action: #selector(dockMenuNext),
            keyEquivalent: ""
        )
        nextItem.target = self
        menu.addItem(nextItem)

        let previousItem = NSMenuItem(
            title: "Previous Track",
            action: #selector(dockMenuPrevious),
            keyEquivalent: ""
        )
        previousItem.target = self
        menu.addItem(previousItem)

        return menu
    }

    @objc private func dockMenuPlayPause() {
        guard let playerService else {
            // Fallback to direct WebView control if PlayerService not available
            SingletonPlayerWebView.shared.playPause()
            return
        }
        Task {
            await playerService.playPause()
        }
    }

    @objc private func dockMenuNext() {
        guard let playerService else {
            // Fallback to direct WebView control if PlayerService not available
            SingletonPlayerWebView.shared.next()
            return
        }
        Task {
            await playerService.nextFromRemoteControl()
        }
    }

    @objc private func dockMenuPrevious() {
        guard let playerService else {
            // Fallback to direct WebView control if PlayerService not available
            SingletonPlayerWebView.shared.previous()
            return
        }
        Task {
            await playerService.previousFromRemoteControl()
        }
    }

    /// Keep app running when the window is closed (for background audio).
    /// Use Cmd+Q to fully quit.
    /// In UI test mode, terminate normally to avoid process conflicts.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        UITestConfig.isUITestMode
    }

    /// Handle reopen (clicking dock icon) when all windows are closed.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        // Show main window when dock icon is clicked
        self.showMainWindowIfNeeded()
        return true
    }

    /// Shows the main window if it's not visible.
    private func showMainWindowIfNeeded() {
        // Try stored reference first
        if let mainWindow {
            if !mainWindow.isVisible {
                mainWindow.makeKeyAndOrderFront(nil)
            }
            return
        }

        // Fallback: find main window by frameAutosaveName
        for window in NSApplication.shared.windows where window.frameAutosaveName == Self.mainWindowAutosaveName {
            self.mainWindow = window
            if !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
            return
        }

        // Last resort: find any main-capable window
        for window in NSApplication.shared.windows where window.canBecomeMain {
            self.mainWindow = window
            if !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
            return
        }
    }
}

// MARK: NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    /// Intercept window close and hide instead, keeping WebView alive for background audio.
    /// In UI test mode, close normally to avoid process conflicts.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // In UI test mode, allow normal close behavior
        if UITestConfig.isUITestMode {
            return true
        }

        // Hide the window instead of closing it
        sender.orderOut(nil)
        return false // Don't actually close
    }
}

// MARK: UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Show notifications even when the app is in the foreground.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner and play sound (if any) even when app is in foreground
        completionHandler([.banner])
    }
}
