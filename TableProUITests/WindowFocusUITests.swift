import XCTest

/// A keyboard-only user has to be able to leave the sidebar.
///
/// The window worked its key view loop out once, before SwiftUI had built the panes, so the loop
/// covered the sidebar and nothing else: the SQL editor and the data grid were never Tab stops, and
/// there was no command that named a pane either. #2904 reported the half of that a user notices.
///
/// Every command here is taken from the menu bar rather than by key equivalent. A menu item carries
/// no geometry, so it is reachable whatever the window is doing, and it exercises the validation
/// arm at the same time. Nothing probes for an item first: XCUITest resolves a menu item by opening
/// its parent, and a probe that resolves it leaves that menu open, so the click's own traversal then
/// fails with "open menu during menu traversal".
final class WindowFocusUITests: UITestCase {
    /// `hasFocus` is declared on `XCUIElementAttributes` in ObjC
    /// (`XCUIAutomation.framework/Headers/XCUIElementAttributes.h:69`) and does not reach Swift:
    /// it appears in no `XCUIAutomation.swiftinterface` for this toolchain, and `hasKeyboardFocus`
    /// is the iOS spelling. Key-value coding is what is left, and it is what an XCUITest
    /// `NSPredicate` on the same attribute would use anyway, without that predicate's app-rooted
    /// query walking the whole tree.
    private func holdsKeyboardFocus(_ element: XCUIElement) -> Bool {
        (element as NSObject).value(forKey: "hasFocus") as? Bool ?? false
    }

    private func chooseFocusCommand(_ title: String, in app: XCUIApplication) {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 20), "The app must publish its menu bar")
        menuBar.menuItems[title].click()
    }

    private func tabUntil(in app: XCUIApplication, limit: Int, _ reached: () -> Bool) -> Bool {
        for _ in 0 ..< limit {
            app.typeKey(XCUIKeyboardKey.tab, modifierFlags: [])
            if reached() { return true }
        }
        return false
    }

    func testFocusObjectListPutsTheKeyboardOnTheSidebarList() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch
        let objectList = window.outlines.firstMatch
        XCTAssertTrue(objectList.waitToExist(timeout: 30), "A connected window lists its objects")

        chooseFocusCommand("Focus Object List", in: app)

        XCTAssertTrue(
            waitForPredicate(timeout: 10) { holdsKeyboardFocus(objectList) },
            "Focus Object List must put the keyboard on the list, not merely reveal it"
        )
    }

    func testFocusSidebarFilterTakesTheKeyboardBack() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch
        let objectList = window.outlines.firstMatch
        let filterField = app.searchFields["sidebar-filter"]
        XCTAssertTrue(objectList.waitToExist(timeout: 30))

        chooseFocusCommand("Focus Object List", in: app)
        XCTAssertTrue(waitForPredicate(timeout: 10) { holdsKeyboardFocus(objectList) })

        chooseFocusCommand("Focus Sidebar Filter", in: app)

        XCTAssertTrue(
            waitForPredicate(timeout: 10) { holdsKeyboardFocus(filterField) },
            "The pair has to work in both directions or the keyboard is trapped in the list"
        )
    }

    /// The reported symptom. Tab is the macOS mechanism for moving focus inside a window, and it has
    /// to reach the list without any command at all.
    func testTabMovesFromTheFilterFieldIntoTheObjectList() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch
        let objectList = window.outlines.firstMatch
        let filterField = app.searchFields["sidebar-filter"]
        XCTAssertTrue(objectList.waitToExist(timeout: 30))

        chooseFocusCommand("Focus Sidebar Filter", in: app)
        XCTAssertTrue(waitForPredicate(timeout: 10) { holdsKeyboardFocus(filterField) })

        /// Not one Tab. With the system's Keyboard Navigation on, the sidebar's view options button
        /// is a legitimate stop between the field and the list, so a fixed count asserts the
        /// reader's System Settings rather than the key view loop.
        XCTAssertTrue(
            tabUntil(in: app, limit: 6) { holdsKeyboardFocus(objectList) },
            "Tab out of the filter field has to reach the list below it"
        )
    }

    /// The part of the loop that was missing entirely: nothing outside the sidebar was ever a Tab
    /// stop, so this fails on a window whose loop is worked out once and never refreshed.
    ///
    /// It names the grid rather than excluding the sidebar's own controls. An exclusion passes the
    /// moment focus reaches any control the test did not think to list, and the sidebar has one more
    /// than it looks: the view options button beside the filter field.
    func testTabReachesTheDataGridOutsideTheSidebar() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch
        let objectList = window.outlines.firstMatch
        let filterField = app.searchFields["sidebar-filter"]
        XCTAssertTrue(objectList.waitToExist(timeout: 30))

        openFirstTable(in: app, window: window, objectList: objectList)
        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "The table has to open a data grid to tab into")

        chooseFocusCommand("Focus Sidebar Filter", in: app)
        XCTAssertTrue(waitForPredicate(timeout: 10) { holdsKeyboardFocus(filterField) })

        XCTAssertTrue(
            tabUntil(in: app, limit: 12) { holdsKeyboardFocus(grid) },
            "Tab never left the sidebar, so the detail panes are not in the key view loop"
        )
    }

    private func openFirstTable(in app: XCUIApplication, window: XCUIElement, objectList: XCUIElement) {
        chooseFocusCommand("Focus Object List", in: app)
        XCTAssertTrue(waitForPredicate(timeout: 10) { holdsKeyboardFocus(objectList) })
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
    }
}
