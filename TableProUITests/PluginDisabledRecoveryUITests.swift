import XCTest

/// A connection whose plugin is switched off used to fail with a message about a plugin that "may be
/// disabled or missing from the PlugIns directory" and a Try Again button that repeated the same
/// failure. SQLite ships inside the app, so switching its plugin off is the deterministic way to
/// reach that state without the network.
final class PluginDisabledRecoveryUITests: UITestCase {
    func testConnectingWithTheDriverSwitchedOffOffersToSwitchItBackOn() throws {
        let app = try launchWithSampleDatabase()

        switchOffSQLitePlugin(in: app)
        disconnect(in: app)

        let reconnect = app.buttons["Reconnect"]
        XCTAssertTrue(reconnect.waitToExist(timeout: 20), "A disconnected window offers Reconnect")
        XCTAssertTrue(waitUntilHittable(reconnect, timeout: 10))
        reconnect.click()

        let enable = app.buttons["Enable Plugin"]
        XCTAssertTrue(
            enable.waitToExist(timeout: 30),
            "A connect whose plugin is off must offer to switch it on, not to try the same connect again"
        )
        XCTAssertTrue(app.staticTexts["Turn the plugin on to connect."].exists)
        XCTAssertTrue(waitUntilHittable(enable, timeout: 10))
        enable.click()

        XCTAssertTrue(
            waitForSampleDatabaseWindow(in: app, timeout: 60),
            "Enable Plugin must switch the plugin on and reconnect"
        )
        XCTAssertFalse(app.buttons["Enable Plugin"].exists)
    }

    private func switchOffSQLitePlugin(in app: XCUIApplication) {
        let settingsItem = app.menuBars.menuItems["Settings…"]
        XCTAssertTrue(settingsItem.waitToExist(timeout: 10))
        settingsItem.click()

        let settings = app.windows["settings"]
        XCTAssertTrue(settings.waitToExist(timeout: 10))
        let pluginsPane = settings.toolbars.buttons["Plugins"]
        XCTAssertTrue(pluginsPane.waitToExist(timeout: 10))
        pluginsPane.click()

        let row = settings.staticTexts["SQLite"].firstMatch
        XCTAssertTrue(row.waitToExist(timeout: 15), "The bundled SQLite plugin is listed under Installed")
        XCTAssertTrue(waitUntilHittable(row, timeout: 10))
        row.click()

        let toggle = settings.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Enable SQLite"))
            .firstMatch
        XCTAssertTrue(toggle.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntilHittable(toggle, timeout: 10))
        toggle.click()

        settings.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(waitForPredicate(timeout: 10) { !settings.exists }, "Settings should close")
    }

    private func disconnect(in app: XCUIApplication) {
        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["Database"].click()
        let disconnectItem = menuBar.menuItems["Disconnect"]
        XCTAssertTrue(disconnectItem.waitToExist(timeout: 10))
        disconnectItem.click()
    }
}
