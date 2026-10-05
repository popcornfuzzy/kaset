import AppKit
import Testing

@testable import Kaset

/// The window's column arithmetic: the width it may not go below, and how wide a side pane may be there.
///
/// These are the numbers behind three reports at once — a window opened too small to hold the Now Playing
/// column, a window that could be dragged narrow enough to cut the page off, and a split view that drew
/// itself wider than the window it was in. Each is a statement about three panes and two dividers, so it is
/// arithmetic, and arithmetic is testable without a window.
///
/// The app's own numbers are `MainWindow.Layout`: a 200pt navigation sidebar, a 765pt page (what the page's
/// content — the player bar — needs before it crops, measured in the running app), a 300pt Now Playing
/// column, and a 900pt floor the window has always had.
@MainActor
@Suite(.tags(.model))
struct WindowShellLayoutTests {
    /// The layout as the app states it.
    private var appLayout: WindowShellLayout {
        WindowShellLayout(
            minSidebarWidth: 200,
            maxSidebarWidth: 300,
            minContentWidth: 765,
            minWindowWidth: 900,
            minInspectorWidth: 300,
            maxInspectorWidth: 560
        )
    }

    @Test("The window's minimum is the panes' sum, and never below the floor the app states")
    func minimumWindowWidthIsThePanesSum() {
        let layout = self.appLayout
        // Closed: 200 + 765 + 2 dividers = 967, which is already above the stated 900pt floor.
        #expect(layout.minimumWindowWidth(tracksColumn: false) == 967)
        // Open: the column's own minimum comes with it — the width the window has to have before the page
        // can keep its own, which is the "the sidebar does not fit" report.
        #expect(layout.minimumWindowWidth(tracksColumn: true) == 1267)

        // The floor wins when the panes need less than it: 200 + 400 + 2 = 602 against a stated 900.
        let roomyFloor = WindowShellLayout(
            minSidebarWidth: 200,
            maxSidebarWidth: 300,
            minContentWidth: 400,
            minWindowWidth: 900,
            minInspectorWidth: 300,
            maxInspectorWidth: 560
        )
        #expect(roomyFloor.minimumWindowWidth(tracksColumn: false) == 900)
        // Open: 200 + 400 + 300 + 2 = 902, which is just past the floor.
        #expect(roomyFloor.minimumWindowWidth(tracksColumn: true) == 902)
    }

    @Test("At its own minimum the panes fit exactly, with the page keeping every point it states")
    func panesFitAtTheMinimumWidth() {
        let layout = self.appLayout
        let minimum = layout.minimumWindowWidth(tracksColumn: true)

        let sidebar = layout.sidebarMaximum(splitWidth: minimum, inspectorWidth: 300, columnOpen: true)
        let inspector = layout.inspectorMaximum(splitWidth: minimum, sidebarWidth: sidebar)

        #expect(sidebar == 200, "the sidebar may not exceed its own minimum when there is no room for it")
        #expect(inspector == 300)
        // The whole point: the three panes and their dividers add up to the window, so nothing has to be
        // drawn past its edge and the page is not squeezed below its minimum.
        #expect(sidebar + layout.minContentWidth + inspector + 2 == minimum)
    }

    @Test("A pane is never capped below its own minimum, however narrow the window is")
    func panesAreNeverCappedBelowTheirMinimum() {
        let layout = self.appLayout
        // A window far below the minimum the app enforces — a state AppKit should never be handed, and the
        // arithmetic has to stay sane for it anyway.
        for width in stride(from: 300, through: 1267, by: 100) {
            let width = CGFloat(width)
            let sidebar = layout.sidebarMaximum(
                splitWidth: width,
                inspectorWidth: 300,
                columnOpen: true
            )
            let inspector = layout.inspectorMaximum(splitWidth: width, sidebarWidth: sidebar)
            #expect(sidebar >= layout.minSidebarWidth)
            #expect(inspector >= layout.minInspectorWidth)
        }
    }

    @Test("A wide window lets the panes reach their own maxima")
    func wideWindowLetsThePanesGrow() {
        let layout = self.appLayout
        // 200 + 765 + 560 + 2 = 1527 is where the column can be as wide as it is ever allowed to be.
        #expect(layout.inspectorMaximum(splitWidth: 1527, sidebarWidth: 200) == 560)
        #expect(layout.inspectorMaximum(splitWidth: 2000, sidebarWidth: 200) == 560)
        // The sidebar reaches its 300 at 300 + 765 + 300 + 2 = 1367.
        #expect(layout.sidebarMaximum(splitWidth: 1367, inspectorWidth: 300, columnOpen: true) == 300)
        // And the two are consistent: what is left for the column after a full-width sidebar is its own
        // share of the same window.
        let sidebar = layout.sidebarMaximum(splitWidth: 1400, inspectorWidth: 300, columnOpen: true)
        let inspector = layout.inspectorMaximum(splitWidth: 1400, sidebarWidth: sidebar)
        #expect(sidebar + layout.minContentWidth + inspector + 2 <= 1400)
    }

    @Test("A closed column does not reserve the column's width")
    func closedColumnDoesNotReserveItsWidth() {
        let layout = self.appLayout
        // With the column closed the sidebar may use the space the column would have taken.
        #expect(layout.sidebarMaximum(splitWidth: 967, inspectorWidth: 300, columnOpen: false) == 200)
        #expect(layout.sidebarMaximum(splitWidth: 1367, inspectorWidth: 300, columnOpen: false) == 300)
        // 200 + 765 + 300 would not fit in 1267 with the column open; with it closed it does.
        #expect(layout.sidebarMaximum(splitWidth: 1267, inspectorWidth: 300, columnOpen: false) == 300)
    }
}
