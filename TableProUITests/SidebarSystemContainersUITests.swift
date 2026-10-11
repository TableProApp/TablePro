import XCTest

/// #2832. The sidebar tree lists system databases and schemas only on request, so the request has to
/// be reachable from the sidebar's own View Options and has to be the same setting Settings shows.
final class SidebarSystemContainersUITests: UITestCase {
    func testViewOptionsTurnsOnTheSettingShownInSettings() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        let viewOptions = window.descendants(matching: .any)
            .matching(identifier: "sidebar-view-options").firstMatch
        XCTAssertTrue(viewOptions.waitToExist(timeout: 10))
        viewOptions.click()

        let entry = app.menuItems["System Databases and Schemas"].firstMatch
        XCTAssertTrue(entry.waitToExist(timeout: 10), "View Options offers System Databases and Schemas")
        entry.click()

        let settingsMenuItem = app.menuBars.menuItems["Settings…"]
        XCTAssertTrue(settingsMenuItem.waitToExist(timeout: 10))
        settingsMenuItem.click()

        let generalPaneButton = app.toolbars.buttons["General"]
        XCTAssertTrue(generalPaneButton.waitToExist(timeout: 10))
        generalPaneButton.click()

        let toggle = app.switches["show-system-containers-toggle"].firstMatch
        XCTAssertTrue(toggle.waitToExist(timeout: 10))
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { isOn(toggle) },
            "Choosing the View Options entry turns on the setting Settings shows"
        )
    }
}
