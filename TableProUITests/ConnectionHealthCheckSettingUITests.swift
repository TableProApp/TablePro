import XCTest

/// The setting behind #2700 is only useful if someone can find it and change it, and a picker that
/// forgets is worse than no picker: the user believes they stopped the traffic and it carries on.
final class ConnectionHealthCheckSettingUITests: UITestCase {
    func testConnectionCheckIntervalIsOfferedAndRemembered() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let settingsMenuItem = app.menuBars.menuItems["Settings…"]
        XCTAssertTrue(settingsMenuItem.waitToExist(timeout: 10))
        settingsMenuItem.click()

        let generalPaneButton = app.toolbars.buttons["General"]
        XCTAssertTrue(generalPaneButton.waitToExist(timeout: 10))
        generalPaneButton.click()

        let picker = app.popUpButtons["connection-health-check-picker"].firstMatch
        XCTAssertTrue(picker.waitToExist(timeout: 10))
        XCTAssertEqual(picker.value as? String, "Every 30 seconds")

        picker.click()
        let onDemand = app.menuItems["Only when I use the connection"]
        XCTAssertTrue(onDemand.waitToExist(timeout: 10))
        onDemand.click()

        XCTAssertEqual(picker.value as? String, "Only when I use the connection")

        generalPaneButton.click()
        XCTAssertEqual(picker.value as? String, "Only when I use the connection")
    }
}
