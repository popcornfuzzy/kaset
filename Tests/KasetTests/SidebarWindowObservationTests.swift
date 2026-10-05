import AppKit
import SwiftUI
import Testing

@testable import Kaset

/// The sidebar's window observations, and the moment they can be installed.
///
/// The coordinator follows the **window**: its key state decides the selected row's emphasis, and who
/// holds its focus is what a page takes away when it focuses a control of its own. Both are facts about
/// a window, and SwiftUI runs `makeNSView`/`updateNSView` while the representable's view is not in one.
/// The observations were installed from there, so they were never installed at all: the rows were stamped
/// once by the retry loop and nothing restored them when AppKit un-emphasised the selected row on the
/// focus change — a grey pill the reader could see, with no effect in the app's source to find.
///
/// This states the arrangement that broke: attach with the view in no window (what SwiftUI does), then
/// put the view in one. The install has to happen on the second step, and `BackingView.viewDidMoveToWindow`
/// is what makes it.
@MainActor
@Suite(.tags(.model))
struct SidebarWindowObservationTests {
    /// Advances the run loop so the view's move into the window is delivered.
    private func pump(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }
    }

    private func host(_ view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.orderBack(nil)
        return window
    }

    @Test("The window observations install when the view enters a window, not before")
    func observationsInstallWhenTheViewEntersAWindow() {
        let configurator = SidebarBackingStyleConfigurator()
        let coordinator = configurator.makeCoordinator()
        let view = SidebarBackingStyleConfigurator.BackingView(frame: NSRect(x: 0, y: 0, width: 240, height: 320))
        view.coordinator = coordinator

        // What SwiftUI does: the view is built and attached with no window behind it yet.
        coordinator.attach(to: view)
        #expect(
            !coordinator.isObservingWindow,
            "the coordinator claimed to be observing a window it has none of"
        )

        let window = self.host(view)
        self.pump(0.5)

        #expect(
            coordinator.isObservingWindow,
            "the sidebar went into a window without ever observing it — the selected row's emphasis can then never be repaired after a page takes the focus"
        )
        window.orderOut(nil)
    }

    @Test("Repeated attaches do not stack a second set of observations")
    func attachingRepeatedlyIsIdempotent() {
        let configurator = SidebarBackingStyleConfigurator()
        let coordinator = configurator.makeCoordinator()
        let view = SidebarBackingStyleConfigurator.BackingView(frame: NSRect(x: 0, y: 0, width: 240, height: 320))
        view.coordinator = coordinator

        let window = self.host(view)
        self.pump(0.2)
        for _ in 0 ..< 5 {
            coordinator.attach(to: view)
        }
        self.pump(0.2)

        #expect(coordinator.isObservingWindow)
        // The window's observers are registered under the key-state notification only once: five attaches
        // must not leave five of them behind, each re-walking every row on a focus change.
        #expect(
            coordinator.windowObserverCount <= 2,
            "the coordinator registered \(coordinator.windowObserverCount) window observers"
        )
        window.orderOut(nil)
    }
}
