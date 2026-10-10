import AppKit
import Testing
@testable import Kaset

/// Tests for the queue rows' right-click menu.
///
/// The menu is what makes a queue row actionable without playing it, and it is the one the Now Playing
/// sidebar's queue page inherits from this panel. It used to be built in a method AppKit never calls —
/// there is no `menuForRow` on `NSTableViewDelegate` — so a right click on a queue row opened nothing at
/// all. These tests state both halves of the fix: the menu the coordinator builds, and the table routing
/// a right click to it.
@Suite(.serialized)
@MainActor
struct QueueSidePanelMenuTests {
    private func makeCoordinator(
        queue: [Song] = TestFixtures.makeSongs(count: 3),
        currentIndex: Int = 0
    ) -> QueueListControllerRepresentable.Coordinator {
        QueueListControllerRepresentable.Coordinator(
            queue: queue,
            currentIndex: currentIndex,
            isPlaying: false,
            // A fresh manager: the shared one loads whatever is pinned on this machine, and the menu's
            // first item is "Add to Favorites" only for a song that is not pinned.
            favoritesManager: FavoritesManager(skipLoad: true),
            onSelect: { _ in },
            onReorder: { _, _ in },
            onRemove: { _ in },
            onStartRadio: { _ in }
        )
    }

    private func menuTitles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    @Test("A queue row's menu offers the song's own actions")
    func rowMenuOffersSongActions() {
        let coordinator = self.makeCoordinator()

        let menu = coordinator.menu(forRow: 1)

        let titles = menu.map(self.menuTitles) ?? []
        #expect(titles.contains("Add to Favorites"))
        #expect(titles.contains("Start Radio"))
        #expect(titles.contains("Share"))
        #expect(titles.contains("Remove from Queue"))
    }

    @Test("The playing row has no Remove from Queue")
    func playingRowCannotBeRemoved() {
        let coordinator = self.makeCoordinator(currentIndex: 1)

        let menu = coordinator.menu(forRow: 1)

        let titles = menu.map(self.menuTitles) ?? []
        #expect(titles.contains("Start Radio"))
        #expect(titles.contains("Remove from Queue") == false)
    }

    @Test("A click below the last row has no menu")
    func clickOutsideTheRowsHasNoMenu() {
        let coordinator = self.makeCoordinator()

        #expect(coordinator.menu(forRow: 3) == nil)
        #expect(coordinator.menu(forRow: -1) == nil)
    }

    @Test("Right-clicking a queue row opens its menu")
    func rightClickOpensTheRowMenu() {
        let queue = TestFixtures.makeSongs(count: 3)
        let coordinator = self.makeCoordinator(queue: queue)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let table = DraggableTableView(frame: NSRect(x: 0, y: 0, width: 350, height: 240))
        table.rowHeight = 56
        table.delegate = coordinator
        table.dataSource = coordinator
        table.coordinator = coordinator
        // Hosted the way the panel hosts it: inside a scroll view, which is what lays the rows out.
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 350, height: 240))
        scrollView.hasVerticalScroller = true
        scrollView.documentView = table
        window.contentView?.addSubview(scrollView)
        table.reloadData()
        table.layoutSubtreeIfNeeded()

        // The middle of the second row, in the window's coordinates — where a right click on that row
        // lands.
        #expect(table.numberOfRows == 3)
        #expect(table.rect(ofRow: 1).isEmpty == false)
        let rowPoint = NSPoint(x: 40, y: table.rect(ofRow: 1).midY)
        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: table.convert(rowPoint, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )

        #expect(event != nil)
        #expect(event.map { table.row(at: table.convert($0.locationInWindow, from: nil)) } == 1)

        let menu = event.flatMap { table.menu(for: $0) }

        let titles = menu.map(self.menuTitles) ?? []
        #expect(titles.contains("Start Radio"))
        #expect(titles.contains("Remove from Queue"))
    }
}
