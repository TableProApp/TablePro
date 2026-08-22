import XCTest

final class DataSettingsUITests: UITestCase {
    func testDataSettingsDoesNotListSavedCustomizations() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let settingsMenuItem = app.menuBars.menuItems["Settings…"]
        XCTAssertTrue(settingsMenuItem.waitToExist(timeout: 10))
        settingsMenuItem.click()

        let dataPaneButton = app.toolbars.buttons["Data"]
        XCTAssertTrue(dataPaneButton.waitToExist(timeout: 10))
        dataPaneButton.click()

        XCTAssertTrue(app.staticTexts["Query History"].waitToExist(timeout: 10))
        XCTAssertFalse(app.staticTexts["Saved Customizations"].exists)
    }
}
