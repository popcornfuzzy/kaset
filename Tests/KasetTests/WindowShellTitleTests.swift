import AppKit
import SwiftUI
import Testing

@testable import Kaset

/// The window's title, and the slot it holds in the toolbar's page region.
///
/// AppKit draws the window's title as a flexible view at the **leading** edge of the region right of the
/// sidebar's tracking separator, and lays the region's items out after it. So the page's own items cannot
/// lead their region while the title is visible, however the app orders them — which is what put the
/// back control next to the page's search/sort controls instead of at the left of the page. The shell
/// hands the slot to the page while there is a back control to place (see
/// `WindowShellController.applyTitleVisibility`).
///
/// This drives the real controller in a real window, because that is the only arrangement in which the
/// rule has any meaning: the title's visibility is the window's.
@MainActor
@Suite(.tags(.model))
struct WindowShellTitleTests {
    private func makeController() -> (WindowShellController, NSWindow) {
        let controller = WindowShellController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.orderBack(nil)
        window.layoutIfNeeded()
        return (controller, window)
    }

    private func apply(canGoBack: Bool, to controller: WindowShellController) {
        controller.apply(
            sidebar: AnyView(EmptyView()),
            content: AnyView(EmptyView()),
            inspector: AnyView(EmptyView()),
            layout: WindowShellLayout(),
            state: WindowShellState(showsInspector: false, seedInspectorWidth: 380),
            toolbar: WindowToolbarItems(
                tracksColumn: false,
                showsAI: false,
                showsNowPlayingToggle: false,
                canGoBack: canGoBack,
                pageControls: nil,
                sidebarHeader: nil,
                onBack: {},
                onAI: {}
            ),
            onInspectorCollapsedChange: { _ in }
        )
    }

    @Test("The title gives up the leading slot to the page's back control, and takes it back at a root")
    func titleYieldsToTheBackControl() {
        let (controller, window) = self.makeController()
        defer { window.orderOut(nil) }

        self.apply(canGoBack: true, to: controller)
        #expect(
            window.titleVisibility == .hidden,
            "the title stayed visible, so the page's back control cannot lead its region"
        )

        self.apply(canGoBack: false, to: controller)
        #expect(
            window.titleVisibility == .visible,
            "the title never came back once the page had no back control"
        )
    }

    @Test("A hidden toolbar keeps the title hidden — the fullscreen Now Playing state is not the shell's to undo")
    func hiddenToolbarKeepsTheTitleHidden() {
        let (controller, window) = self.makeController()
        defer { window.orderOut(nil) }

        // What `MainWindow.updateWindowTitleVisibility` does for the fullscreen experience: both go away.
        window.toolbar = NSToolbar(identifier: NSToolbar.Identifier("Kaset.tests.hiddenToolbar"))
        window.titleVisibility = .hidden
        window.toolbar?.isVisible = false

        self.apply(canGoBack: false, to: controller)
        #expect(
            window.titleVisibility == .hidden,
            "the shell un-hid the title while the toolbar itself was hidden"
        )
    }
}
