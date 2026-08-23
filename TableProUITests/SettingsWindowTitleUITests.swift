import XCTest

final class SettingsWindowTitleUITests: UITestCase {
    /// The window is found by its accessibility identifier, never by its title: the title is the
    /// thing under test, so matching on it would pass without the window ever being retitled.
    func testTheSettingsWindowTitleFollowsTheSelectedPane() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let settingsMenuItem = app.menuBars.menuItems["Settings…"]
        XCTAssertTrue(settingsMenuItem.waitToExist(timeout: 10))
        settingsMenuItem.click()

        let settingsWindow = app.windows["settings"]
        XCTAssertTrue(settingsWindow.waitToExist(timeout: 10))

        for pane in ["Keyboard", "Appearance", "Plugins", "Editor", "General"] {
            let paneButton = app.toolbars.buttons[pane]
            XCTAssertTrue(paneButton.waitToExist(timeout: 10))
            paneButton.click()

            XCTAssertTrue(
                waitForPredicate(timeout: 5) { settingsWindow.title == pane },
                "The settings window has to be titled \(pane), it is titled \(settingsWindow.title)"
            )
        }
    }
}
