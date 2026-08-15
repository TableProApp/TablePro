import XCTest

/// Closing a connection used to be a command that could not be seen to do anything: it closed a
/// subset of one connection's tabs and left the row that invoked it exactly where it was, and on a
/// connection with no session it resolved no coordinator and returned in silence.
///
/// These drive the command through the menu bar rather than the connections strip, because the
/// strip only appears once a second connection is open and the sample database is a single-file
/// SQLite connection. The command is the same one the strip's row invokes.
final class ConnectionCloseUITests: UITestCase {
    /// The regression test for the reported bug: choosing Close must have an observable effect.
    ///
    /// The observable is the command's own enablement, which is `hasSelectedWorkspace`: true while
    /// a window is showing a connection and false once none is. Asserting on the editor view
    /// instead made the test depend on which kind of tab the sample database happens to open with,
    /// which is not what this is testing. The sample connection has no unsaved work, so it takes
    /// the close-without-asking path.
    func testClosingTheOnlyConnectionLeavesNoConnectionShowing() throws {
        let app = try launchWithSampleDatabase()

        XCTAssertTrue(
            waitForCloseConnection(in: app, toBeEnabled: true, timeout: 30),
            "Opening the sample database must leave a connection showing"
        )
        closeConnectionItem(in: app).click()

        XCTAssertTrue(
            waitForCloseConnection(in: app, toBeEnabled: false, timeout: 20),
            "Closing the connection must leave none showing, not leave the window as it was"
        )
    }

    /// Opens the File menu and reports the item's enablement, closing the menu again so the next
    /// poll starts from the same state. A menu item only answers `isEnabled` while its menu is up.
    private func waitForCloseConnection(
        in app: XCUIApplication,
        toBeEnabled expected: Bool,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let item = closeConnectionItem(in: app)
            guard item.waitForExistence(timeout: 5) else { continue }
            let isEnabled = item.isEnabled
            app.typeKey(.escape, modifierFlags: [])
            if isEnabled == expected { return true }
        }
        return false
    }

    private func closeConnectionItem(in app: XCUIApplication) -> XCUIElement {
        let menuBar = app.menuBars.firstMatch
        menuBar.menuBarItems["File"].click()
        return menuBar.menuItems["Close Connection"]
    }
}
