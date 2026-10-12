import AppKit
import XCTest

/// Issue #3016. The Favorites tab loads its queries after its first render, and nothing told SwiftUI
/// when that load landed, so the tab kept whatever it was built with. The reported symptom was a
/// missing Queries section beside the favorite tables; on a connection with no favorites at all the
/// same gap left the spinner up for good, which is what this drives because it needs no seeding.
final class SidebarFavoritesFirstEntryUITests: UITestCase {
    func testTheFavoritesTabSettlesOnItsFirstEntry() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 30))

        showFavorites(in: app)

        let noFavorites = window.staticTexts["No Favorites"]
        XCTAssertTrue(
            noFavorites.waitToExist(timeout: 15),
            """
            One switch to Favorites has to settle on a finished state. The sample database has no \
            favorites, so that state is the onboarding view; a tab still showing its spinner means \
            the load finished with nothing listening.
            """
        )
    }

    /// `View > Show Favorites` rather than the Favorites segment of the sidebar's scope control. The
    /// menu item is the route that does not depend on the sidebar being laid out, and this test is
    /// about what the tab shows on its very first entry, not about how it was reached; the scope
    /// control has its own case in `ConnectionWindowChromeUITests`.
    private func showFavorites(in app: XCUIApplication) {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 10))
        menuBar.menuBarItems["View"].click()

        let showFavorites = menuBar.menuItems["Show Favorites"]
        XCTAssertTrue(showFavorites.waitToExist(timeout: 5), "View > Show Favorites must be reachable")
        showFavorites.click()
    }
}
