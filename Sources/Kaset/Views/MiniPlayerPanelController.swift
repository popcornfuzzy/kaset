import AppKit
import os
import SwiftUI

// MARK: - MiniPlayerPanelController

/// Owns the detached mini player's window.
///
/// ## Why a panel, and why the app owns it
///
/// A detached player is only useful if it outlives the window it came from, so this is a real
/// `NSWindow` the app creates and keeps, not a SwiftUI scene: the main window is AppKit's already
/// ([ADR-0030](../../docs/adr/0030-appkit-window-shell.md)), and a `Window` scene would make this
/// window's lifetime SwiftUI's while the surface it hosts is the app's singleton WebView.
///
/// It is an `NSPanel` because that is what a floating utility window is on macOS, and because the
/// two things a companion player needs are panel behaviours:
///
/// - **`.nonactivatingPanel`**: clicking the player to pause it must not activate Kaset and pull
///   focus off whatever the reader was doing. A panel with this style still receives the click and
///   the transport still works, which is exactly the "control my music without leaving my work"
///   contract a detached player has.
/// - **`.utilityWindow`**: the smaller, shadowed, titled chrome — the shape macOS gives a companion
///   window, and the one that does not compete with the main window for attention.
///
/// ## Why it floats
///
/// `level = .floating` with `.canJoinAllSpaces` and `.fullScreenAuxiliary` keeps the player visible
/// over the reader's other apps and on every Space — a detached player that hides behind the window
/// you switched to is not a detached player. `becomesKeyOnlyIfNeeded` is the other half of the
/// non-activating contract: the panel takes the keyboard only when something in it needs it, so
/// pressing play never steals the reader's focus.
///
/// ## The surface
///
/// The panel's content is `MiniPlayerPanel`, which hosts the shared player surface only while
/// `PlayerService.playerSurfaceHost` is `.miniPlayerPanel`. The panel never claims the surface on its
/// own: `AppDelegate` hands it over when the panel opens and takes it back when the panel closes, so
/// there is one owner at a time and the WebView is never re-parented behind the app's back.
@available(macOS 26.0, *)
@MainActor
final class MiniPlayerPanelController: NSWindowController, NSWindowDelegate {
    /// Called when the reader closes the panel, so the app can take the player surface back.
    var onClose: (() -> Void)?

    private let playerService: PlayerService
    private let settings: SettingsManager
    private let logger = DiagnosticsLogger.player

    /// Set while the controller closes its own window, so that close is not reported back as the
    /// reader's action.
    private var isClosingProgrammatically = false

    /// - Parameter contentViewController: the panel's SwiftUI, already carrying its environment.
    ///   Passed in because the services are the app's and this controller is not the app: it cannot
    ///   build a view that needs `PlayerService` and `WebKitManager` without being handed them.
    init(
        playerService: PlayerService,
        settings: SettingsManager,
        contentViewController: NSViewController
    ) {
        self.playerService = playerService
        self.settings = settings

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: MiniPlayerPanelLayout.defaultWidth, height: 300),
            styleMask: [
                .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
                .utilityWindow, .nonactivatingPanel,
            ],
            backing: .buffered,
            defer: false
        )

        super.init(window: panel)

        // The artwork is the window's own backdrop (see `MiniPlayerPanel`), so the titlebar is part
        // of the surface rather than a band above it — the same chrome the main window uses.
        panel.title = "Mini Player"
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The panel is a card the reader can move by its artwork, the way a floating player should be.
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.delegate = self
        panel.contentViewController = contentViewController

        // The panel's size follows the track's own video ratio, so the picture is never letterboxed
        // inside a frame sized for a different one. The bounds are stated here and enforced on every
        // resize, so the reader cannot drag it into a shape the layout cannot draw.
        self.applySizeBounds()
        self.applyRestoredSize()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("MiniPlayerPanelController is created in code")
    }

    private var layout: MiniPlayerPanelLayout {
        MiniPlayerPanelLayout(
            aspectRatio: self.playerService.miniPlayerVideoAspectRatio.map { CGFloat($0) }
        )
    }

    // MARK: - Presentation

    /// Shows the panel, keeping the size and position it was last left at.
    ///
    /// `orderFrontRegardless` rather than `makeKeyAndOrderFront`: the panel is non-activating by
    /// design, and asking for key would defeat that.
    func show() {
        guard let panel = self.window else { return }
        self.applySizeBounds()
        self.applyRestoredSize()
        panel.orderFrontRegardless()
        self.logger.info("Mini player panel shown")
    }

    /// Closes the panel if it is open. Does not report the close back; the caller is taking the
    /// surface back itself.
    ///
    /// Named `dismiss` rather than `close` because `NSWindowController.close()` exists and means
    /// something slightly different (it closes the window whether or not it is visible).
    func dismiss() {
        guard let panel = self.window, panel.isVisible else { return }
        self.isClosingProgrammatically = true
        panel.close()
        self.isClosingProgrammatically = false
        self.logger.info("Mini player panel closed")
    }

    /// Whether the panel is currently on screen.
    var isPanelVisible: Bool {
        self.window?.isVisible ?? false
    }

    // MARK: - Size

    private func applySizeBounds() {
        guard let panel = self.window else { return }
        let layout = self.layout
        panel.contentMinSize = layout.contentSize(forWidth: MiniPlayerPanelLayout.minimumWidth)
        panel.contentMaxSize = layout.contentSize(forWidth: MiniPlayerPanelLayout.maximumWidth)
    }

    /// Restores the reader's size, or places the panel beside the main window the first time.
    private func applyRestoredSize() {
        guard let panel = self.window else { return }

        // A remembered frame is the reader's; only a panel that has never been placed is derived from
        // the main window. `setFrameAutosaveName` returning false is the only case that repositions.
        let hasRestoredFrame = panel.setFrameAutosaveName(Self.autosaveName)

        guard hasRestoredFrame, panel.contentLayoutRect.size.width > 0 else {
            let width = MiniPlayerPanelLayout.clampedWidth(
                CGFloat(self.settings.miniPlayerPanelWidth)
            )
            let size = self.layout.contentSize(forWidth: width)
            panel.setContentSize(size)
            panel.setFrame(
                MiniPlayerPanelPlacement.frame(
                    size: size,
                    mainWindowFrame: self.mainWindowFrame,
                    visibleScreenFrame: self.visibleScreenFrame
                ),
                display: false
            )
            return
        }

        // The ratio may have changed since the frame was saved (a different track), so the height is
        // re-derived while the reader's width is kept.
        let width = panel.contentLayoutRect.size.width
        panel.setContentSize(self.layout.contentSize(forWidth: width))
        self.settings.miniPlayerPanelWidth = Double(width)
    }

    /// The main window's frame, for placing the panel beside it.
    private var mainWindowFrame: CGRect {
        NSApplication.shared.windows
            .first { $0.frameAutosaveName == AppDelegate.mainWindowAutosaveName }?
            .frame ?? self.visibleScreenFrame
    }

    private var visibleScreenFrame: CGRect {
        let screen = self.window?.screen ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
    }

    private static let autosaveName = "KasetMiniPlayerPanel"

    // MARK: - NSWindowDelegate

    func windowWillClose(_: Notification) {
        guard !self.isClosingProgrammatically else { return }
        // The reader closed the panel (its close button, or ⌘W while it was key): the app takes the
        // player surface back, so playback video returns to the main window rather than being
        // stranded in a window that no longer exists.
        self.logger.info("Mini player panel closed by the reader; returning the player surface")
        self.onClose?()
    }
}
