import XCTest

// #2904: the key view loop was worked out before SwiftUI built the panes, so Tab never left the sidebar.
final class WindowFocusUITests: UITestCase {
    func testTabWalksTheWindowAndFocusCommandsJumpBack() throws {
        let launch = try launchWithFixture()
        let app = launch.app
        let window = launch.window
        let objectList = objectBrowser(in: window)
        let filterField = window.searchFields["sidebar-filter"]

        let album = objectBrowserRow("album", in: window)
        XCTAssertTrue(album.waitToExist(timeout: 20), "The object browser must list album")
        clickAtCenter(album)
        let grid = dataGrid(in: window)
        XCTAssertTrue(waitForClickableRows(in: grid), "The table has to open a data grid to tab into")

        app.typeShortcut(.focusSidebarFilter)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.holdsKeyboardFocus(filterField) },
            "Focus Sidebar Filter must put the keyboard in the filter field"
        )
        // Not a fixed count: with Keyboard Navigation on, the view options button is a stop before the list.
        XCTAssertTrue(
            tabUntil(in: app, limit: 6) { self.holdsKeyboardFocus(objectList) },
            "Tab out of the filter field has to reach the list below it"
        )
        XCTAssertTrue(
            tabUntil(in: app, limit: 12) { self.holdsKeyboardFocus(grid) },
            "Tab never left the sidebar, so the detail panes are not in the key view loop"
        )

        app.typeShortcut(.focusObjectList)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.holdsKeyboardFocus(objectList) },
            "Focus Object List must put the keyboard on the list, not merely reveal it"
        )
        app.typeShortcut(.focusSidebarFilter)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.holdsKeyboardFocus(filterField) },
            "The pair has to work in both directions or the keyboard is trapped in the list"
        )
    }

    private func tabUntil(in app: XCUIApplication, limit: Int, _ reached: () -> Bool) -> Bool {
        for _ in 0 ..< limit {
            app.typeKey(.tab, modifierFlags: [])
            if reached() { return true }
        }
        return false
    }
}
