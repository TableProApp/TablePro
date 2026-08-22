import XCTest

/// Command W has to close the window in front. It was bound to a command only a connection
/// window answered, so it did nothing in Settings, in the integrations activity window, or in
/// any viewer the app opens, and the welcome window had to answer that command by hand to get
/// its own shortcut back.
///
/// Windows are found by their accessibility identifier, not their title: the settings window
/// titles itself after the pane on show, so it reads "Data" as often as "Settings".
final class AuxiliaryWindowCloseUITests: UITestCase {
    private func launchShowingWelcome() throws -> XCUIApplication {
        let app = try launchApp()
        XCTAssertTrue(app.windows["welcome"].waitToExist(timeout: 10))
        return app
    }

    private func openWindow(_ identifier: String, from menuItem: String, in app: XCUIApplication) -> XCUIElement {
        let item = app.menuBars.menuItems[menuItem]
        XCTAssertTrue(item.waitToExist(timeout: 10), "\(menuItem) must be in the menu bar")
        item.click()
        let window = app.windows[identifier]
        XCTAssertTrue(window.waitToExist(timeout: 10), "\(menuItem) must open the \(identifier) window")
        return window
    }

    /// The welcome window is left open behind each of these, so a passing assertion means Command W
    /// closed the window in front rather than any window it could reach.
    private func assertCommandWCloses(_ window: XCUIElement, in app: XCUIApplication) {
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { !window.exists },
            "Command W must close the front window"
        )
        XCTAssertTrue(app.windows["welcome"].exists, "Command W must not reach past the front window")
    }

    func testCommandWClosesTheSettingsWindow() throws {
        let app = try launchShowingWelcome()
        assertCommandWCloses(openWindow("settings", from: "Settings…", in: app), in: app)
    }

    func testCommandWClosesTheIntegrationsActivityWindow() throws {
        let app = try launchShowingWelcome()
        assertCommandWCloses(openWindow("integrations-activity", from: "Integrations…", in: app), in: app)
    }

    /// The welcome window used to answer the editor's own close command to get Command W back.
    /// It closes through the standard one now, with nothing of its own in the way.
    func testCommandWClosesTheWelcomeWindow() throws {
        let app = try launchShowingWelcome()
        let welcome = app.windows["welcome"]
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { !welcome.exists },
            "Command W must close the welcome window"
        )
    }
}
