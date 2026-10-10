import AppKit
import SwiftUI
import Testing
@testable import Kaset

/// The Now Playing sidebar's queue page and the width it gives the queue.
///
/// The queue is the column's one page that is **not** inset by `NowPlayingSidebarLayout.padding`, and the
/// padding is what this measures: a queue row is its own band — the playing row's tint is drawn across the
/// row's whole width — so a page inset drew a grey gutter beside the coloured band, on both sides of the
/// column. The rows carry their own insets instead, which is a different thing and a different view
/// (`QueueTableCellView`).
///
/// The queue itself is AppKit, so the page is hosted at the column's floor and the scroll view the table
/// lives in is read back in the hosting view's own coordinates: at 300pt the queue must start at the
/// page's leading edge and end at its trailing one, where an inset would show it starting at 14 and
/// ending 14 early.
@MainActor
@Suite(.tags(.model))
struct NowPlayingSidebarQueuePageTests {
    /// The queue's own height at the column's floor; only the horizontal geometry is the question.
    private static let pageSize = CGSize(width: 300, height: 600)

    /// Advances the run loop so the hosted page lays out and its representable's view exists.
    private func pump(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }
    }

    /// The scroll view the page's own table lives in.
    ///
    /// The page's only AppKit view is that scroll view — the queue's rows are inside it — so the first one
    /// in the hosted hierarchy is the queue.
    private func queueScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView, scrollView.documentView is NSTableView {
            return scrollView
        }
        for subview in view.subviews {
            if let found = self.queueScrollView(in: subview) { return found }
        }
        return nil
    }

    private func hostPage() -> NSWindow {
        let playerService = PlayerService()
        playerService.queue = TestFixtures.makeSongs(count: 4)
        let hosting = NSHostingView(
            rootView: NowPlayingSidebarQueuePage()
                .environment(playerService)
                .environment(FavoritesManager(skipLoad: true))
        )
        hosting.frame = NSRect(origin: .zero, size: Self.pageSize)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderBack(nil)
        self.pump(0.4)
        return window
    }

    @Test("The queue page gives the queue the column's full width, with no page inset")
    func queuePageHasNoHorizontalInset() throws {
        let window = self.hostPage()
        defer { window.orderOut(nil) }
        let hosting = try #require(window.contentView)

        let scrollView = try #require(
            self.queueScrollView(in: hosting),
            "the page hosts no queue table"
        )
        let frame = scrollView.convert(scrollView.bounds, to: hosting)

        // Flush with both edges: an inset would show as a leading 14pt and a trailing 14pt.
        #expect(frame.minX < 0.5, "the queue starts \(frame.minX)pt into the column")
        #expect(
            frame.maxX > Self.pageSize.width - 0.5,
            "the queue ends \(Self.pageSize.width - frame.maxX)pt early"
        )
    }
}
