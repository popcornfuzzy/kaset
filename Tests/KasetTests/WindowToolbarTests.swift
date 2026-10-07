import AppKit
import SwiftUI
import Testing

@testable import Kaset

/// The window toolbar's item order.
///
/// The order is the mechanism, not a detail: each tracking separator bounds the region before it, and the
/// region's items are laid out against its trailing edge — so "the page's controls stop at the Now Playing
/// column" is a statement about this array, and about nothing else. It is covered here because the window
/// it drives cannot be.
@Suite("Window toolbar item order")
@MainActor
struct WindowToolbarLayoutTests {
    private func items(
        tracksColumn: Bool = false,
        showsAI: Bool = false,
        showsNowPlayingToggle: Bool = false,
        canGoBack: Bool = false,
        hasPageControls: Bool = false,
        hasSidebarHeader: Bool = false
    ) -> WindowToolbarItems {
        WindowToolbarItems(
            tracksColumn: tracksColumn,
            showsAI: showsAI,
            showsNowPlayingToggle: showsNowPlayingToggle,
            canGoBack: canGoBack,
            pageControls: hasPageControls
                ? PageToolbarContribution(id: "test", content: AnyView(EmptyView()))
                : nil,
            sidebarHeader: hasSidebarHeader
                ? NowPlayingSidebarToolbarHeader(title: "Up Next", onBack: {})
                : nil,
            onBack: {},
            onAI: {}
        )
    }

    @Test("A window with only a sidebar is the sidebar's own toggle and separator")
    func sidebarOnly() throws {
        let identifiers = self.items().identifiers
        #expect(identifiers.first == .toggleSidebar)
        let separator = try #require(identifiers.firstIndex(of: .sidebarTrackingSeparator))
        #expect(separator == 1)
        #expect(identifiers.count == 2)
    }

    @Test("The page's back control is the first item in the page's own region, and only while it can pop")
    func backControlLeadsThePageRegion() throws {
        let identifiers = self.items(canGoBack: true, hasPageControls: true).identifiers
        let separator = try #require(identifiers.firstIndex(of: .sidebarTrackingSeparator))
        let back = try #require(identifiers.firstIndex(of: WindowToolbarItem.back))
        #expect(back == separator + 1, "the back control must lead the region the sidebar bounds")
        let controls = try #require(identifiers.firstIndex(of: WindowToolbarItem.pageControls))
        #expect(back < controls, "it comes before anything the page does")
    }

    @Test("A page that cannot pop has no back control")
    func noBackControlAtTheRoot() {
        #expect(!self.items().identifiers.contains(WindowToolbarItem.back))
        #expect(!self.items(tracksColumn: true, hasPageControls: true).identifiers.contains(WindowToolbarItem.back))
    }

    @Test("An open column adds its tracking separator")
    func openColumn() {
        #expect(self.items(tracksColumn: true).identifiers.contains(.inspectorTrackingSeparator))
    }

    @Test("A closed column has no inspector region and no separator")
    func closedColumnHasNoRegion() {
        #expect(!self.items().identifiers.contains(.inspectorTrackingSeparator))
    }

    @Test("The column's toggle is the window's last item, open or closed")
    func toggleIsLast() {
        #expect(self.items(showsNowPlayingToggle: true).identifiers.last == WindowToolbarItem.nowPlaying)
        let open = self.items(tracksColumn: true, showsNowPlayingToggle: true).identifiers
        #expect(open.last == WindowToolbarItem.nowPlaying)
    }

    @Test("While the column is open the toggle is pushed to the inspector region's trailing edge")
    func toggleIsTrailingInTheInspectorRegion() throws {
        let identifiers = self.items(tracksColumn: true, showsNowPlayingToggle: true).identifiers
        let separator = try #require(identifiers.firstIndex(of: .inspectorTrackingSeparator))
        let space = try #require(identifiers.firstIndex(of: .flexibleSpace))
        let toggle = try #require(identifiers.firstIndex(of: WindowToolbarItem.nowPlaying))
        // Without the space the item would sit against the separator — the leading edge of the region
        // above the column — instead of the window's trailing edge, where an inspector toggle belongs.
        #expect(separator < space)
        #expect(space < toggle)
    }

    @Test("The page's controls sit before the column's tracking separator, not after it")
    func pageControlsAreBoundedByTheColumn() throws {
        let identifiers = self.items(tracksColumn: true, hasPageControls: true).identifiers
        let controls = try #require(identifiers.firstIndex(of: WindowToolbarItem.pageControls))
        let separator = try #require(identifiers.firstIndex(of: .inspectorTrackingSeparator))
        #expect(controls < separator)
    }

    @Test("One flexible space pushes the page's controls to the region's trailing edge")
    func oneFlexibleSpacePushesTheRun() throws {
        let identifiers = self.items(hasPageControls: true).identifiers
        let space = try #require(identifiers.firstIndex(of: .flexibleSpace))
        let controls = try #require(identifiers.firstIndex(of: WindowToolbarItem.pageControls))
        #expect(space < controls)
        #expect(identifiers.filter { $0 == .flexibleSpace }.count == 1)
    }

    @Test("With nothing right-aligned there is nothing to push, and no flexible space")
    func noRunMeansNoFlexibleSpace() {
        #expect(!self.items().identifiers.contains(.flexibleSpace))
        #expect(!self.items(tracksColumn: true).identifiers.contains(.flexibleSpace))
    }

    @Test("A page with no controls adds no item")
    func noContributionMeansNoItem() {
        #expect(!self.items(tracksColumn: true).identifiers.contains(WindowToolbarItem.pageControls))
    }

    @Test("The column's header leads the region above the column, and the toggle still trails it")
    func sidebarHeaderLeadsTheColumnRegion() throws {
        let identifiers = self.items(
            tracksColumn: true,
            showsNowPlayingToggle: true,
            hasSidebarHeader: true
        ).identifiers
        let separator = try #require(identifiers.firstIndex(of: .inspectorTrackingSeparator))
        let header = try #require(identifiers.firstIndex(of: WindowToolbarItem.sidebarHeader))
        #expect(header == separator + 1, "the column's header must lead the region above the column")
        // The header is not part of a right-aligned run, so the flexible space after it still pushes only
        // the toggle to the window's trailing edge.
        let space = try #require(identifiers.firstIndex(of: .flexibleSpace))
        let toggle = try #require(identifiers.firstIndex(of: WindowToolbarItem.nowPlaying))
        #expect(header < space)
        #expect(space < toggle)
        #expect(identifiers.filter { $0 == .flexibleSpace }.count == 1)
    }

    @Test("The column's header item is a hosted view, and the header it draws has a size")
    func sidebarHeaderIsHosted() throws {
        let controller = WindowToolbarController()
        let item = try #require(
            controller.toolbar(
                NSToolbar(identifier: NSToolbar.Identifier("Kaset.tests.header")),
                itemForItemIdentifier: WindowToolbarItem.sidebarHeader,
                willBeInsertedIntoToolbar: true
            )
        )
        #expect(item.view is NSHostingView<AnyView>)

        // The header is the same shape the column used to draw itself, so it must lay out to more than
        // nothing — a hosted view that collapses to zero width is an item the toolbar would draw as a gap.
        let host = NSHostingView(
            rootView: NowPlayingSidebarToolbarHeaderView(
                header: NowPlayingSidebarToolbarHeader(title: "Up Next", onBack: {})
            )
        )
        host.layout()
        #expect(host.fittingSize.width > 20)
        #expect(host.fittingSize.height > 10)
    }

    @Test("No column header without a page of the column, and none while the column is closed")
    func noSidebarHeaderWithoutAPage() {
        #expect(!self.items(tracksColumn: true).identifiers.contains(WindowToolbarItem.sidebarHeader))
        // A closed column has no region above it, so the header has nowhere to be drawn.
        #expect(
            !self.items(hasSidebarHeader: true).identifiers.contains(WindowToolbarItem.sidebarHeader),
            "a header was stated for a column that is not open"
        )
    }

    @Test("The AI button and the page's controls share one right-aligned run, AI first")
    func sharedRightAlignedRun() throws {
        let identifiers = self.items(showsAI: true, hasPageControls: true).identifiers
        let space = try #require(identifiers.firstIndex(of: .flexibleSpace))
        let ai = try #require(identifiers.firstIndex(of: WindowToolbarItem.ai))
        let controls = try #require(identifiers.firstIndex(of: WindowToolbarItem.pageControls))
        #expect(space < ai)
        #expect(ai < controls)
    }

    @Test("Two bordered controls are separated, so macOS cannot draw them as one capsule")
    func borderedControlsAreSeparated() throws {
        let identifiers = self.items(showsAI: true, hasPageControls: true).identifiers
        let ai = try #require(identifiers.firstIndex(of: WindowToolbarItem.ai))
        let controls = try #require(identifiers.firstIndex(of: WindowToolbarItem.pageControls))
        // macOS 26 fills one glass capsule behind a contiguous run of items. A fixed space is a real item,
        // so the run is broken and the Ask AI button and the page's controls keep their own shapes.
        #expect(controls == ai + 2)
        #expect(identifiers[ai + 1] == .space)
    }

    @Test("A lone bordered control needs no separator")
    func loneControlKeepsNoSeparator() {
        #expect(!self.items(hasPageControls: true).identifiers.contains(.space))
        #expect(!self.items(showsAI: true).identifiers.contains(.space))
    }
}

/// The name the Now Playing column's header shows, per page.
///
/// The column draws no header of its own any more, so this is what the toolbar puts in the band above the
/// column — and the overview must state none, because it *is* the top of the column: there is nothing
/// above it to go back to, and no name to label it with.
@Suite("Now Playing column header titles")
@MainActor
struct NowPlayingSidebarHeaderTitleTests {
    @Test("Every page but the overview names itself")
    func pageTitles() {
        #expect(NowPlayingSidebarPage.overview.toolbarTitle == nil)
        #expect(NowPlayingSidebarPage.lyrics.toolbarTitle != nil)
        #expect(NowPlayingSidebarPage.queue.toolbarTitle != nil)
        // Two pages, two names: a header that showed the same word for both would not say where the
        // reader is.
        #expect(NowPlayingSidebarPage.lyrics.toolbarTitle != NowPlayingSidebarPage.queue.toolbarTitle)
    }
}

/// What the page on screen publishes, and what happens when pages come and go.
@Suite("Page toolbar contributions")
@MainActor
struct PageToolbarModelTests {
    @Test("A page's controls are published, and taken away again by the same page")
    func publishAndRetract() {
        let model = PageToolbarModel()
        #expect(model.contribution == nil)

        model.contribute(PageToolbarContribution(id: "library", content: AnyView(EmptyView())))
        #expect(model.contribution?.id == "library")

        model.retract(id: "library")
        #expect(model.contribution == nil)
    }

    @Test("A retraction from a page that is no longer published is ignored")
    func staleRetractionIsIgnored() {
        let model = PageToolbarModel()
        model.contribute(PageToolbarContribution(id: "library", content: AnyView(EmptyView())))
        // The incoming page appears before the outgoing one disappears, so the outgoing page's retraction
        // must not clear the controls the reader is now looking at.
        model.contribute(PageToolbarContribution(id: "playlist-1", content: AnyView(EmptyView())))

        model.retract(id: "library")

        #expect(model.contribution?.id == "playlist-1")
    }

    @Test("The last page to publish wins")
    func lastPublisherWins() {
        let model = PageToolbarModel()
        model.contribute(PageToolbarContribution(id: "library", content: AnyView(EmptyView())))
        model.contribute(PageToolbarContribution(id: "history", content: AnyView(EmptyView())))

        #expect(model.contribution?.id == "history")
    }
}
