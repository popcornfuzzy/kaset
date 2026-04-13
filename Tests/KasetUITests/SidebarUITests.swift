import XCTest

/// UI tests for sidebar navigation.
@MainActor
final class SidebarUITests: KasetUITestCase {
    // MARK: - Navigation Items Visible

    func testSidebarShowsAllNavigationItems() {
        launchDefault()

        // Verify all sidebar items are present via accessibility identifiers
        let searchItem = app.buttons[TestAccessibilityID.Sidebar.searchItem]
        let homeItem = app.buttons[TestAccessibilityID.Sidebar.homeItem]
        let exploreItem = app.buttons[TestAccessibilityID.Sidebar.exploreItem]
        let likedMusicItem = app.buttons[TestAccessibilityID.Sidebar.likedMusicItem]
        let playlistsItem = app.buttons[TestAccessibilityID.Sidebar.libraryItem]

        XCTAssertTrue(searchItem.waitForExistence(timeout: 10), "Search item should exist")
        XCTAssertTrue(homeItem.exists, "Home item should exist")
        XCTAssertTrue(exploreItem.exists, "Explore item should exist")
        XCTAssertTrue(likedMusicItem.exists, "Liked Music item should exist")
        XCTAssertTrue(playlistsItem.exists, "Playlists item should exist")
    }

    // MARK: - Navigation Selection

    func testNavigateToHome() {
        launchDefault()

        navigateToHome()

        // Verify Home view is displayed (check for navigation title)
        let navigationTitle = app.staticTexts["Home"]
        XCTAssertTrue(waitForElement(navigationTitle), "Home navigation title should be visible")
    }

    func testNavigateToSearch() {
        launchDefault()

        navigateToSearch()

        // Verify Search view is displayed
        let navigationTitle = app.staticTexts["Search"]
        XCTAssertTrue(waitForElement(navigationTitle), "Search navigation title should be visible")

        // Search field should be present
        let searchField = app.textFields.firstMatch
        XCTAssertTrue(searchField.exists, "Search field should exist")
    }

    func testNavigateToExplore() {
        launchDefault()

        navigateToExplore()

        // Verify Explore view is displayed
        let navigationTitle = app.staticTexts["Explore"]
        XCTAssertTrue(waitForElement(navigationTitle), "Explore navigation title should be visible")
    }

    func testNavigateToLikedMusic() {
        launchDefault()

        navigateToLikedMusic()

        // Verify Liked Music view is displayed
        let navigationTitle = app.staticTexts["Liked Music"]
        XCTAssertTrue(waitForElement(navigationTitle), "Liked Music navigation title should be visible")
    }

    func testNavigateToLibrary() {
        launchDefault()

        navigateToLibrary()

        // Verify Library view is displayed
        let navigationTitle = app.staticTexts["Library"]
        XCTAssertTrue(waitForElement(navigationTitle), "Library navigation title should be visible")
    }

    func testLibraryDisclosureIsVisibleByDefault() {
        launchDefault()

        navigateToLibrary()

        let libraryDisclosure = app.otherElements[TestAccessibilityID.Sidebar.libraryDisclosure].firstMatch
        XCTAssertTrue(
            libraryDisclosure.waitForExistence(timeout: 10),
            "Library disclosure should be visible in sidebar"
        )
    }

    func testNavigateToPlaylistFromSidebar() {
        launchDefault()

        let libraryDisclosure = app.otherElements[TestAccessibilityID.Sidebar.libraryDisclosure].firstMatch
        XCTAssertTrue(libraryDisclosure.waitForExistence(timeout: 10), "Library disclosure should be visible in sidebar")
        libraryDisclosure.click()

        let playlistItem = app.buttons[TestAccessibilityID.Sidebar.playlistItem("playlist-0")].firstMatch
        XCTAssertTrue(playlistItem.waitForExistence(timeout: 10), "First playlist should be visible in sidebar")

        playlistItem.click()

        let detailTitle = app.staticTexts["My Playlist 1"].firstMatch
        XCTAssertTrue(waitForElement(detailTitle), "Playlist detail title should be visible after sidebar navigation")
    }

    // MARK: - Navigation Persistence

    func testNavigationPersistsAfterSwitching() {
        launchDefault()

        // Navigate to Search
        navigateToSearch()
        let searchTitle = app.staticTexts["Search"]
        XCTAssertTrue(waitForElement(searchTitle))

        // Navigate to Explore
        navigateToExplore()
        let exploreTitle = app.staticTexts["Explore"]
        XCTAssertTrue(waitForElement(exploreTitle))

        // Navigate back to Home
        navigateToHome()
        let homeTitle = app.staticTexts["Home"]
        XCTAssertTrue(waitForElement(homeTitle))
    }
}
