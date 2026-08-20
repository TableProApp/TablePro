import XCTest

final class DataSettingsUITests: UITestCase {
    func testDataSettingsDoesNotListSavedCustomizations() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let settingsMenuItem = app.menuBars.menuItems["Settings..."]
        XCTAssertTrue(settingsMenuItem.waitForExistence(timeout: 10))
        settingsMenuItem.click()

        let dataPaneButton = app.toolbars.buttons["Data"]
        XCTAssertTrue(dataPaneButton.waitForExistence(timeout: 10))
        dataPaneButton.click()

        XCTAssertTrue(app.staticTexts["Query History"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Saved Customizations"].exists)
    }
}
