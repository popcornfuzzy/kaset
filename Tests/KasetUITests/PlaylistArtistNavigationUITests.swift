import CoreGraphics
import XCTest

/// Regression tests for the header's artist credit.
///
/// The credit in a playlist/album header pushes `ArtistDetailView`. Pressing Back used to leave the
/// app unresponsive — the window kept painting the previous page but stopped answering events, and
/// the main thread never returned. These tests drive the path a user takes (open a playlist, click
/// the credited artist, press Back) and assert afterwards that the page is back *and* the app still
/// answers accessibility queries, which is what fails when the main thread is stuck.
///
/// Albums and playlists share the same header, so covering Liked Music covers both routes.
///
/// They need UI test mode, which is what `Scripts/run-ui-tests.sh` sets up: the app must be built
/// and installed at `/Applications/Kaset.app`, and mock mode is switched on through a marker file,
/// because macOS drops the launch arguments a sandboxed runner passes on (see `docs/testing.md`).
///
/// ```bash
/// Scripts/run-ui-tests.sh KasetUITests/PlaylistArtistNavigationUITests
/// ```
@MainActor
final class PlaylistArtistNavigationUITests: KasetUITestCase {
    /// Identifiers of the credited-artist links in the header. The artist ID is part of the
    /// identifier, so the tests match the prefix and stay independent of the account's data.
    private static let artistCreditPrefix = "playlistDetailView.artistCredit."

    /// Mirrors `PlaylistDetailView.artworkSize`.
    private static let artworkSize: CGFloat = 180

    func testLikedMusicArtistCreditThenBackLeavesAppResponsive() {
        // A frozen app can stall an accessibility query past its timeout, so bound the whole test.
        self.executionTimeAllowance = 240

        self.launchDefault()

        // A debug build can spend a while on launch work before the sidebar is up.
        let likedMusicItem = self.app.buttons[TestAccessibilityID.Sidebar.likedMusicItem].firstMatch
        XCTAssertTrue(self.waitQuietly(likedMusicItem, timeout: 90), "the sidebar should appear after launch")

        self.navigateToLikedMusic()

        let credit = self.artistCredit
        XCTAssertTrue(
            self.waitQuietly(credit, timeout: 30),
            "Liked Music should show a clickable artist credit in its header.\n\(self.app.debugDescription)"
        )

        // The backdrop behind the header, sampled before the trip. Coming back must leave it
        // unchanged: the list used to keep its row decoration painted over the whole header row,
        // which showed up as a full-width accent-coloured band (see ADR-0014).
        let before = self.headerBackdropPixel(near: credit)

        // The window can sit behind another app's, and a click XCUITest cannot hit-test silently
        // lands nowhere (`Falling back to element center point`). Front the app, and fail loudly on
        // the frame instead of waiting out the navigation timeout.
        self.app.activate()
        XCTAssertTrue(
            self.waitUntilHittable(credit, timeout: 15),
            "The artist credit is not clickable: \(credit.frame) in window \(self.app.windows.firstMatch.frame)."
        )

        credit.click()

        // The playlist page is replaced by the artist page; the credit's disappearance is the push.
        XCTAssertTrue(
            self.waitForElementToDisappear(credit, timeout: 25),
            "Clicking the credit should open the artist page.\n\(self.app.debugDescription)"
        )

        self.pressBack()

        // The regression: after the pop the playlist must be back *and* the app must still respond.
        // When the main thread spins, this query never resolves and the test fails here.
        XCTAssertTrue(
            self.waitQuietly(credit, timeout: 25),
            "The Liked Music header should be back after pressing Back, and the app must still answer accessibility queries.\n\(self.app.debugDescription)"
        )

        // A second round trip. The header used to keep its row activation after the first push, and
        // a repeat click on the credit was ignored until some *other* row was clicked.
        Thread.sleep(forTimeInterval: 1)
        credit.click()
        XCTAssertTrue(
            self.waitForElementToDisappear(credit, timeout: 25),
            "the artist page should open again after returning.\n\(self.app.debugDescription)"
        )

        self.pressBack()
        XCTAssertTrue(
            self.waitQuietly(credit, timeout: 25),
            "The Liked Music header should be back after a second round trip.\n\(self.app.debugDescription)"
        )

        let after = self.headerBackdropPixel(near: credit)
        guard let before, let after else {
            XCTFail("Could not sample the header backdrop (before: \(String(describing: before)), after: \(String(describing: after)))")
            return
        }

        let delta = max(
            abs(before.red - after.red),
            max(abs(before.green - after.green), abs(before.blue - after.blue))
        )
        XCTContext.runActivity(named: "header backdrop before: \(before), after: \(after), delta: \(delta)") { _ in }
        XCTAssertLessThan(
            delta,
            24,
            "The header backdrop changed after returning from the artist page (before: \(before), after: \(after)). The list is painting a decoration over the header."
        )

        // And it must not be tinted in the first place: the table used to paint its row highlight
        // over the whole header — accent red while the window was key, gray while it was not.
        let spread = before.red - min(before.green, before.blue)
        XCTAssertLessThan(
            spread,
            40,
            "The header is tinted (sampled \(before)), which is the table's row highlight over the header."
        )
    }

    // MARK: - Header layout

    /// The header's action row lines up with the thumbnail, the header does not stretch, and the page
    /// stays inside the window.
    ///
    /// The header used to be the list's first row, so the table fixed its height. Above the list it
    /// became a flexible child of the page's stack, and the stack shared the space the tracks list
    /// left over with it: the buttons drifted ~140 pt down and the header grew to ~310 pt. Forcing
    /// the header to its ideal height then made the list claim the container's full height, so the
    /// page measured 961 pt in a 734 pt window, and the stack centred the overflow — the header slid
    /// up until its top half, and the toolbar's controls over it, were clipped off the window.
    func testHeaderActionRowSitsOnTheThumbnail() {
        self.executionTimeAllowance = 240

        self.launchDefault()

        let likedMusicItem = self.app.buttons[TestAccessibilityID.Sidebar.likedMusicItem].firstMatch
        XCTAssertTrue(self.waitQuietly(likedMusicItem, timeout: 90), "the sidebar should appear after launch")

        self.navigateToLikedMusic()

        let artwork = self.app.descendants(matching: .any)[TestAccessibilityID.PlaylistDetail.artwork].firstMatch
        XCTAssertTrue(
            self.waitQuietly(artwork, timeout: 30),
            "the header thumbnail should be visible.\n\(self.app.debugDescription)"
        )

        let play = self.app.buttons[TestAccessibilityID.PlaylistDetail.playButton].firstMatch
        XCTAssertTrue(self.waitQuietly(play, timeout: 15), "the header should show the play button")

        let credit = self.artistCredit
        XCTAssertTrue(self.waitQuietly(credit, timeout: 15), "the header should show the artist credit")

        let window = self.app.windows.firstMatch
        XCTContext.runActivity(
            named: "window=\(window.frame) artwork=\(artwork.frame) play=\(play.frame) credit=\(credit.frame)"
        ) { _ in }

        // The header has to be *inside* the window. When the header+list need more height than the
        // window offers, the stack centres the overflow and the page slides up until the header's top
        // half — and the toolbar's controls with it — is clipped off the window.
        XCTAssertTrue(
            window.frame.contains(artwork.frame),
            "The header thumbnail \(artwork.frame) is outside the window \(window.frame)."
        )

        // The thumbnail is 180 pt; the header is this plus its 24 pt insets. Stretching shows up as a
        // far taller thumbnail container.
        XCTAssertLessThan(
            artwork.frame.height,
            Self.artworkSize + 24,
            "The header is \(artwork.frame.height) pt tall for a \(Self.artworkSize) pt thumbnail, so it is absorbing the tracks list's leftover height."
        )

        XCTAssertLessThanOrEqual(
            play.frame.maxY,
            artwork.frame.maxY + 8,
            "The action row (\(play.frame)) should end with the thumbnail (\(artwork.frame)) instead of being pushed below it."
        )

        // The buttons are bottom-aligned on purpose, so a large gap here means the header stretched
        // and the spacer absorbed the difference.
        XCTAssertLessThan(
            play.frame.minY - credit.frame.maxY,
            100,
            "\(play.frame.minY - credit.frame.maxY) pt of empty space between the credits and the buttons: the header is stretching."
        )

        // The header belongs to the scrolling content. It spent a while pinned above the list, which
        // is what this pins down: swiping the list has to carry the thumbnail with it.
        let artworkTop = artwork.frame.minY
        artwork.swipeUp()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(
            !artwork.exists || artwork.frame.minY < artworkTop - 40,
            "The header is pinned: after swiping, the thumbnail is at \(artwork.frame) and was at \(artworkTop)."
        )
    }

    // MARK: - Toolbar

    /// The search field and the refresh button sit next to each other in the playlist toolbar.
    /// They used to be laid out on top of each other (the search pill covering the refresh
    /// control), which is what this pins down.
    func testPlaylistToolbarControlsDoNotOverlap() {
        self.executionTimeAllowance = 240

        self.launchDefault()

        let likedMusicItem = self.app.buttons[TestAccessibilityID.Sidebar.likedMusicItem].firstMatch
        XCTAssertTrue(self.waitQuietly(likedMusicItem, timeout: 90), "the sidebar should appear after launch")

        self.navigateToLikedMusic()

        self.assertToolbarControlsAreSeparate(in: "Liked Music, which has a sort menu")
    }

    /// The same toolbar without a sort menu.
    ///
    /// The sort item is only added for a playlist that can be sorted. With just the search field and
    /// the refresh button left, the toolbar drew them inside one shared glass capsule and the refresh
    /// glyph ended up on the search pill's trailing edge — the two read as a single control. The
    /// capsule is a rendering detail the accessibility tree does not expose, so this checks the
    /// layout the capsule is built from: the controls keep a gap between them and the refresh button
    /// is not inside the search field.
    func testToolbarControlsStaySeparateWithoutASortMenu() {
        self.executionTimeAllowance = 240

        self.launchDefault()

        let libraryItem = self.app.buttons[TestAccessibilityID.Sidebar.libraryItem].firstMatch
        XCTAssertTrue(self.waitQuietly(libraryItem, timeout: 90), "the sidebar should appear after launch")
        XCTAssertTrue(
            self.clickWhenHittable(libraryItem),
            "the Library sidebar item never became clickable: \(libraryItem.frame)."
        )

        // A library playlist carries no sort menu (only Liked Music and owned playlists do). The
        // library's playlist card is a plain button around its title, so the title is what can be
        // matched here. (The sidebar's disclosure button is not in the accessibility tree, which is
        // why the sidebar route is not used.)
        let playlistCardTitle = self.app.staticTexts["My Playlist 1"].firstMatch
        if !self.waitQuietly(playlistCardTitle, timeout: 45) {
            // The library page can come up without its content on a loaded machine; re-selecting it
            // is harmless and gives the fetch a second chance.
            XCTAssertTrue(self.clickWhenHittable(libraryItem), "the Library sidebar item never became clickable")
        }

        XCTAssertTrue(
            self.waitQuietly(playlistCardTitle, timeout: 30),
            "the library should list its playlists.\n\(self.app.debugDescription)"
        )
        XCTAssertTrue(
            self.clickWhenHittable(playlistCardTitle),
            "the library's first playlist never became clickable: \(playlistCardTitle.frame)."
        )

        XCTAssertFalse(
            self.app.buttons["Sort"].firstMatch.exists,
            "this playlist should not offer a sort menu"
        )

        self.assertToolbarControlsAreSeparate(in: "a library playlist, which has no sort menu")
    }

    /// Asserts the toolbar's search field and refresh button are laid out as two separate controls.
    private func assertToolbarControlsAreSeparate(in context: String) {
        let searchField = self.app.textFields
            .matching(NSPredicate(format: "placeholderValue == %@", "Search in playlist"))
            .firstMatch
        XCTAssertTrue(self.waitQuietly(searchField, timeout: 30), "the playlist search field should be in the toolbar (\(context))")

        let refreshButton = self.app.buttons["arrow.clockwise"].firstMatch
        XCTAssertTrue(self.waitQuietly(refreshButton, timeout: 15), "the refresh button should be in the toolbar (\(context))")

        let search = searchField.frame
        let refresh = refreshButton.frame
        XCTContext.runActivity(named: "\(context): search=\(search) refresh=\(refresh)") { _ in }

        // The shared capsule both controls used to be drawn in is not part of the accessibility
        // tree, so keep a screenshot: whether the two items share one background is a rendering
        // detail that only the pixels show (`xcrun xcresulttool export attachments`).
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "playlist toolbar"
        screenshot.lifetime = .keepAlways
        self.add(screenshot)

        XCTAssertFalse(
            search.intersects(refresh),
            "The search field \(search) overlaps the refresh button \(refresh) (\(context))."
        )

        // `contains` also catches a refresh glyph that was merged into the search pill's frame.
        XCTAssertFalse(
            search.contains(refresh),
            "The refresh button \(refresh) sits inside the search field \(search) (\(context))."
        )

        XCTAssertGreaterThanOrEqual(
            refresh.minX - search.maxX,
            4,
            "Only \(refresh.minX - search.maxX) pt between the search field and the refresh button (\(context)): they are sharing one control."
        )
    }

    // MARK: - Header backdrop

    private struct RGB: CustomStringConvertible {
        let red: Int
        let green: Int
        let blue: Int

        var description: String { "rgb(\(self.red), \(self.green), \(self.blue))" }
    }

    /// Samples the backdrop in the header row's empty area, to the right of the credits.
    private func headerBackdropPixel(near element: XCUIElement) -> RGB? {
        let frame = element.frame
        guard frame != .zero else { return nil }
        return self.pixelColor(at: CGPoint(x: frame.midX + 250, y: frame.midY))
    }

    /// Reads one pixel from the current screen at the given point.
    private func pixelColor(at point: CGPoint) -> RGB? {
        let screenshot = XCUIScreen.main.screenshot()
        guard let cgImage = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let scale = CGFloat(cgImage.width) / screenshot.image.size.width
        let x = Int((point.x * scale).rounded())
        let y = Int((point.y * scale).rounded())
        guard x >= 0, y >= 0, x < cgImage.width, y < cgImage.height else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Place the requested pixel at the origin of the 1×1 context.
        context.draw(
            cgImage,
            in: CGRect(x: -x, y: -(cgImage.height - 1 - y), width: cgImage.width, height: cgImage.height)
        )

        return RGB(red: Int(pixel[0]), green: Int(pixel[1]), blue: Int(pixel[2]))
    }

    // MARK: - Steps

    /// The credited artist link in the current page's header.
    private var artistCredit: XCUIElement {
        self.app.buttons.matching(identifierPrefix: Self.artistCreditPrefix).firstMatch
    }

    /// Presses the navigation stack's Back button, falling back to the standard ⌘[ shortcut.
    private func pressBack() {
        let backButton = self.app.buttons["chevron.backward"].firstMatch
        if self.waitQuietly(backButton, timeout: 5), backButton.isHittable {
            backButton.click()
            return
        }

        let labeledBack = self.app.buttons["Back"].firstMatch
        if self.waitQuietly(labeledBack, timeout: 3), labeledBack.isHittable {
            labeledBack.click()
            return
        }

        self.app.typeKey("[", modifierFlags: .command)
    }

    /// Waits for an element without failing the test, so callers can try one marker then another.
    private func waitQuietly(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Clicks an element once it is clickable, fronting the app in between attempts. The window can
    /// sit behind another app's, and a click XCUITest cannot hit-test silently lands nowhere.
    private func clickWhenHittable(_ element: XCUIElement, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            self.app.activate()
            if element.exists, element.isHittable {
                element.click()
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        return false
    }

    /// Waits for an element to become clickable. A false `isHittable` means something is over it —
    /// another window, or a view that swallowed the click.
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

private extension XCUIElementQuery {
    /// Matches elements whose accessibility identifier starts with `prefix`.
    func matching(identifierPrefix prefix: String) -> XCUIElementQuery {
        self.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }
}
