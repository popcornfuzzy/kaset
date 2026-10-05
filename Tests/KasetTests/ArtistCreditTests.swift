import Foundation
import Testing
@testable import Kaset

/// What the artist credit in a playlist/album header is allowed to be built from.
///
/// Five mechanisms have been through this control, and only the last one works in the running app:
///
/// - **A value-based `NavigationLink`** — what the song context menus use for Go to Artist, and what a
///   lone credit was for a while. It resolves against the nearest enclosing `NavigationStack`, so it
///   needs nothing installed anywhere, and it works. Its cost is the list's row selection: the header is
///   a row, the row that starts a navigation is selected by the table, and the highlight stays painted
///   over the whole header — accent while the window was key, gray while it was not — for the rest of the
///   page's life, with the row's activation kept so a second click on the same credit is swallowed.
/// - **A `Menu` of links** for albums that credit two or more artists, because a `List` row hands a click
///   to *every* link inside it: with one link per artist, both fired and the stack always landed on the
///   *last* artist, whichever name was clicked. A menu's items avoid the row's activation, but the header
///   row still gets selected when a navigation starts from it, so the painted header came back with it.
/// - **A stack-provided environment action** (`navigateToArtist`, with every stack calling
///   `pushesArtists(onPath:)`). In the app the credit read the *default* action on every click — the
///   unified log filled up with "Artist credit … was clicked with no navigation stack providing an
///   action" — so an album opened from a list did nothing. A hosted test that pushes pages onto a stack
///   and calls the action from the pushed page (and from a `List` row inside it) passes, which is why this
///   one is not covered by that kind of test any more.
/// - **A `navigationDestination` on the page itself** (`item:` with the artist in the page's state). The
///   page is already a destination of the stack that shows it, and a second destination on the same stack
///   hangs the app: the main thread never returned from `NSHostingView.layout`, under
///   `PlaylistDetailView.body` and an `OutlineListCoordinator` update. It took a click in the real app to
///   see it; text pages in a hosted test do not reproduce it.
/// - **The header as the tracks section's header** — where the control lived to escape the row model. On
///   macOS a section header is a floating group row: it parks itself on top of the tracks for the whole
///   scroll, and a navigation started from it still selects it, so the sticky band and the painted header
///   arrive together.
///
/// What ships instead: the header is the list's first row (it scrolls, and the table measures it), and the
/// credit is a plain button per artist that pushes onto the enclosing stack's path — a path the page is
/// handed as `onNavigateToArtist`, since a pushed page cannot reach the path itself and must not register a
/// second destination. A button is not a navigation source, so the row is never selected; every credit is
/// its own control, so an album crediting several artists opens the one that was clicked.
///
/// These tests are source guards because the failures above are invisible to the in-process tests this
/// project can run without launching the app.
@Suite(.tags(.model))
struct ArtistCreditTests {
    /// `PlaylistDetailView`'s source, from the test file's own location.
    private static let playlistDetailViewSource: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // the file
        .deletingLastPathComponent() // KasetTests
        .deletingLastPathComponent() // Tests
        .appending(path: "Sources/Kaset/Views/PlaylistDetailView.swift")

    /// The code of `creditsView(_:)` and of the credit control it renders, without comments: the doc
    /// comments above them name the mechanisms that must not come back.
    private func creditsSource() throws -> String {
        let source = try String(contentsOf: Self.playlistDetailViewSource, encoding: .utf8)
        let start = try #require(source.range(of: "private func creditsView("))
        let end = try #require(source.range(of: "private func headerButtons("))
        let region = source[start.lowerBound ..< end.lowerBound]

        return region
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("The credit pushes through the page's own closure instead of a NavigationLink")
    func creditPushesThroughTheInjectedClosure() throws {
        let credits: String = try self.creditsSource()

        #expect(
            credits.contains("self.onNavigateToArtist(artist)"),
            """
            The header's artist credit must push the artist onto the stack's path. Pushing is the page's \
            only option: it is handed the path as `onNavigateToArtist` because a pushed page cannot reach \
            the enclosing stack's path, and it must not register a destination of its own. See ADR-0023.
            """
        )

        #expect(
            !credits.contains("NavigationLink"),
            """
            No NavigationLink may render the credit. The credit sits in the header row, and a link there \
            makes the table select that row: it paints the row's selection over the whole header and keeps \
            the row's activation, so a second click on the same credit is swallowed — and it hands one \
            click to every link in the row, which is what made a two-artist album always open its last \
            artist. See ADR-0023.
            """
        )

        #expect(
            !credits.contains("Menu("),
            "The credits are a row of buttons, not a menu: a menu hid the two-artist case behind a click."
        )

        #expect(
            credits.contains("ForEach(Array(detail.artists.enumerated()), id: \\.element.id)"),
            "Each credited artist is its own control, so a click opens the artist it landed on."
        )
    }

    @Test("The page registers no navigation destination of its own")
    func pageRegistersNoDestination() throws {
        let source = try String(contentsOf: Self.playlistDetailViewSource, encoding: .utf8)

        #expect(
            !source.contains(".navigationDestination"),
            """
            PlaylistDetailView is a destination of the stack that shows it, and a second destination \
            on that stack does not push — it pins the main thread in layout until the window stops \
            answering. See ADR-0023.
            """
        )
    }

    @Test("The header is the list's first row, not a section header")
    func headerIsARowNotASectionHeader() throws {
        let source = try String(contentsOf: Self.playlistDetailViewSource, encoding: .utf8)

        // Indentation is not the point, so the row is matched across any leading whitespace.
        let headerIsARow = source.range(
            of: #"self\.headerView\(detail\)\s*\.listRowSeparator\(\.hidden\)"#,
            options: .regularExpression
        ) != nil
        #expect(
            headerIsARow,
            """
            The header must be the list's first row: it scrolls away with the tracks and the table \
            measures it. See ADR-0023.
            """
        )

        #expect(
            !source.contains("} header: {"),
            """
            The header must not be a section header. On macOS a List's section header is a floating \
            group row: it sticks on top of the tracks for the whole scroll, and a navigation started \
            from it still selects it, so the sticky band and the painted header come back together. \
            See ADR-0023.
            """
        )
    }
}
