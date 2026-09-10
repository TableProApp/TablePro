import XCTest

/// The License pane as an unlicensed install sees it, which is what a UI test run always is:
/// `UITestCase` launches against throwaway storage with no license activated.
final class LicenseSettingsUITests: UITestCase {
    func testLicensePaneOffersActivationWhenUnlicensed() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let settingsMenuItem = app.menuBars.menuItems["Settings…"]
        XCTAssertTrue(settingsMenuItem.waitToExist(timeout: 10))
        settingsMenuItem.click()

        let licensePaneButton = app.toolbars.buttons["License"]
        XCTAssertTrue(licensePaneButton.waitToExist(timeout: 10))
        licensePaneButton.click()

        let keyField = app.textFields["license-key-field"]
        XCTAssertTrue(keyField.waitToExist(timeout: 10), "An unlicensed pane must offer a key field")

        let activateButton = app.buttons["license-activate-button"]
        XCTAssertTrue(activateButton.exists)
        XCTAssertFalse(activateButton.isEnabled, "Activate stays disabled until a key is typed")

        XCTAssertFalse(
            app.staticTexts["Devices"].exists,
            "Seats belong to a license; an unlicensed pane has none to show"
        )
    }

    func testSyncMovedOutOfTheLicensePane() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let settingsMenuItem = app.menuBars.menuItems["Settings…"]
        XCTAssertTrue(settingsMenuItem.waitToExist(timeout: 10))
        settingsMenuItem.click()

        let syncPaneButton = app.toolbars.buttons["Sync"]
        XCTAssertTrue(syncPaneButton.waitToExist(timeout: 10), "Sync now owns its own pane")
        syncPaneButton.click()

        XCTAssertTrue(app.staticTexts["iCloud Sync"].waitToExist(timeout: 10))

        let licensePaneButton = app.toolbars.buttons["License"]
        XCTAssertTrue(licensePaneButton.exists)
        licensePaneButton.click()

        XCTAssertTrue(app.textFields["license-key-field"].waitToExist(timeout: 10))
        XCTAssertFalse(
            app.staticTexts["iCloud Sync"].exists,
            "Sync left the license pane; being gated by a license is not a reason to live in it"
        )
    }
}
