import XCTest

/// Switch Connection is the command that leaves the connection in front of you, and it used to be
/// disabled by that connection going away. It validated on `isConnected` and ran through the
/// selected connection's command actions, both of which die with the session, so the Database menu
/// greyed it out and `Ctrl+Cmd+C` did nothing over the pane telling the user to reconnect or pick
/// another connection. The connections strip and the View menu survived; the switcher did not, and
/// it is the only route to a connection that is not open yet.
///
/// One connection is enough to pin this. The strip needs a second connection to appear and the
/// sample database is a single-file SQLite connection, the same reason `ConnectionCloseUITests`
/// drives its command from the menu bar. What this asserts is the command's own enablement, which
/// is what the bug was.
final class SwitchConnectionAfterDisconnectUITests: UITestCase {
    func testSwitchConnectionStaysEnabledAfterDisconnecting() throws {
        let app = try launchWithSampleDatabase()

        XCTAssertTrue(
            waitForDatabaseItem(named: "Switch Connection…", in: app, toBeEnabled: true, timeout: 30),
            "Opening the sample database must leave the switcher reachable"
        )

        databaseItem(named: "Disconnect", in: app).click()

        XCTAssertTrue(
            waitForDatabaseItem(named: "Reconnect", in: app, toBeEnabled: true, timeout: 20),
            "Disconnect must leave the window offering a reconnect, which is how we know it landed"
        )
        XCTAssertTrue(
            waitForDatabaseItem(named: "Switch Connection…", in: app, toBeEnabled: true, timeout: 20),
            "Switch Connection must survive the connection it switches away from"
        )
    }

    /// A menu item only answers `isEnabled` while its menu is up, so each poll opens the menu and
    /// closes it again, leaving the next one starting from the same state.
    private func waitForDatabaseItem(
        named title: String,
        in app: XCUIApplication,
        toBeEnabled expected: Bool,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let item = databaseItem(named: title, in: app)
            guard item.waitToExist(timeout: 5) else { continue }
            let isEnabled = item.isEnabled
            app.typeKey(.escape, modifierFlags: [])
            if isEnabled == expected { return true }
        }
        return false
    }

    private func databaseItem(named title: String, in app: XCUIApplication) -> XCUIElement {
        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["Database"].click()
        return menuBar.menuItems[title]
    }
}
