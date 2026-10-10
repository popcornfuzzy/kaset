import AppKit
import Testing
@testable import Kaset

/// What a press on a queue row does to that row.
///
/// A table hides the row under the pointer while it prepares a drag, and the drag session is what shows
/// it again. So a row the table refuses as a drag source — or a press that never became a drag — strands
/// that row invisible, and a recycled row view keeps the hidden flag, which makes it permanent. The queue
/// row that is playing used to be exactly that case: refused as a source and invisible for good after a
/// drag. These tests state both halves: every row offers a drag, and a release puts a stranded row back.
@Suite(.serialized)
@MainActor
struct QueueRowDragStrandTests {
    private func makeCoordinator(
        queue: [Song] = TestFixtures.makeSongs(count: 5),
        currentIndex: Int = 2
    ) -> QueueListControllerRepresentable.Coordinator {
        QueueListControllerRepresentable.Coordinator(
            queue: queue,
            currentIndex: currentIndex,
            isPlaying: false,
            favoritesManager: FavoritesManager(skipLoad: true),
            onSelect: { _ in },
            onReorder: { _, _ in },
            onRemove: { _ in },
            onStartRadio: { _ in }
        )
    }

    /// A table hosted the way the panel hosts it: inside a scroll view, in a real window.
    private func makeTable(dataSource: NSTableViewDataSource) -> (NSWindow, DraggableTableView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let table = DraggableTableView(frame: NSRect(x: 0, y: 0, width: 350, height: 400))
        table.rowHeight = 56
        // The rows live in a column, as they do in the panel: showing and hiding a row's inline button
        // asks the table for its view *at that column*, which raises on a table that has none.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("QueueColumn"))
        column.width = 350
        table.addTableColumn(column)
        table.delegate = dataSource as? NSTableViewDelegate
        table.dataSource = dataSource
        table.coordinator = dataSource as? QueueListControllerRepresentable.Coordinator
        table.registerForDraggedTypes([NSPasteboard.PasteboardType("com.kaset.queueitem"), .string])
        table.verticalMotionCanBeginDrag = true
        table.draggingDestinationFeedbackStyle = .gap

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 350, height: 400))
        scrollView.hasVerticalScroller = true
        scrollView.documentView = table
        window.contentView?.addSubview(scrollView)
        table.reloadData()
        table.layoutSubtreeIfNeeded()
        return (window, table)
    }

    private func mouse(
        _ type: NSEvent.EventType,
        in window: NSWindow,
        of table: DraggableTableView,
        atRow row: Int
    ) -> NSEvent? {
        let local = NSPoint(x: 60, y: table.rect(ofRow: row).midY)
        return NSEvent.mouseEvent(
            with: type,
            location: table.convert(local, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }

    /// Runs the run loop long enough for a view animation to land.
    private func settle() {
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }
    }

    @Test("Every row offers a drag, the playing one included")
    func everyRowIsADragSource() {
        let queue = TestFixtures.makeSongs(count: 4)
        let coordinator = self.makeCoordinator(queue: queue, currentIndex: 1)
        let (_, table) = self.makeTable(dataSource: coordinator)

        // A row that refuses a drag source is a row that vanishes on press (see the test below), so there
        // must not be one — the lock is stated at the drop instead.
        for row in queue.indices {
            #expect(
                coordinator.tableView(table, pasteboardWriterForRow: row) != nil,
                "row \(row) is not a drag source"
            )
        }
    }

    @Test("The table's drop feedback refuses exactly what the model refuses")
    func dropsAroundThePlayingRowAreRefused() {
        let queue = TestFixtures.makeSongs(count: 5)
        let coordinator = self.makeCoordinator(queue: queue, currentIndex: 2)

        // Every destination for the playing row itself: it can be lifted, but there is nowhere to put it.
        for destination in 0 ... queue.count {
            #expect(
                coordinator.dropIsAllowed(from: 2, to: destination) == false,
                "the playing row was droppable at \(destination)"
            )
        }
        // A drag that would carry the playing row with it, from either side.
        #expect(coordinator.dropIsAllowed(from: 0, to: 4) == false)
        #expect(coordinator.dropIsAllowed(from: 4, to: 0) == false)
        // …and the moves that leave it where it is, which the queue must still allow.
        #expect(coordinator.dropIsAllowed(from: 0, to: 1))
        #expect(coordinator.dropIsAllowed(from: 3, to: 4))
    }

    @Test("The release shows a row a press left hidden, and slides back the one it left shifted")
    func aStrandedRowComesBackOnRelease() {
        let coordinator = self.makeCoordinator(queue: TestFixtures.makeSongs(count: 4), currentIndex: 3)
        let (window, table) = self.makeTable(dataSource: coordinator)

        guard let stranded = table.rowView(atRow: 2, makeIfNecessary: false),
              let up = self.mouse(.leftMouseUp, in: window, of: table, atRow: 0)
        else {
            Issue.record("the table is not ready for a press")
            return
        }

        // What the table's drag preparation leaves behind when the drag never begins (and what a recycled
        // row view keeps): the row is there, invisible, faded, and out of its slot. It is written by hand
        // because the press that writes it is inside AppKit's own drag loop, which no test can drive.
        stranded.isHidden = true
        stranded.alphaValue = 0
        var shifted = stranded.frame
        shifted.origin.x -= 40
        stranded.frame = shifted

        table.mouseUp(with: up)

        #expect(stranded.isHidden == false)
        #expect(stranded.alphaValue == 1)
        #expect(stranded.frame.origin.x == table.rect(ofRow: 2).origin.x)
    }

    @Test("The release leaves a revealed delete action where the swipe put it")
    func revealedDeleteActionIsLeftAlone() {
        let coordinator = self.makeCoordinator(queue: TestFixtures.makeSongs(count: 4), currentIndex: 0)
        let (window, table) = self.makeTable(dataSource: coordinator)

        table.revealDeleteActionForRow(1)
        guard let up = self.mouse(.leftMouseUp, in: window, of: table, atRow: 1),
              let rowView = table.rowView(atRow: 1, makeIfNecessary: false)
        else {
            Issue.record("the row was not revealed")
            return
        }
        #expect(table.isDeleteActionRevealed(for: 1), "the reveal did not start")
        self.settle()

        // The swipe slid the row left to make room for the Remove action.
        let revealedX = rowView.frame.origin.x
        #expect(revealedX < table.rect(ofRow: 1).origin.x)

        table.mouseUp(with: up)

        // The release must not slide the revealed row back under the reader's finger.
        #expect(rowView.frame.origin.x == revealedX)
    }
}
