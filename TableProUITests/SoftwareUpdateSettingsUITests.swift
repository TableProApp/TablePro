import XCTest

/// Updates install in the background from this release on, so the two controls that reverse that
/// and the one that slows it down are the whole of the user's consent. A pane that does not offer
/// them is a default flipped with no way back.
///
/// Nothing here writes an update preference. Sparkle reads and writes them through `SUHost`, which
/// uses `NSUserDefaults.standard` for the main bundle, so a click on one of these controls lands
/// in the real `com.TablePro` domain rather than the UI-test suite, and the runner is sandboxed
/// away from clearing it again. A case that flipped a toggle would change the update behaviour of
/// the machine it ran on and leak into every later case.
final class SoftwareUpdateSettingsUITests: UITestCase {
    func testSoftwareUpdateControlsAreOffered() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let settingsMenuItem = app.menuBars.menuItems["Settings…"]
        XCTAssertTrue(settingsMenuItem.waitToExist(timeout: 10))
        settingsMenuItem.click()

        let generalPaneButton = app.toolbars.buttons["General"]
        XCTAssertTrue(generalPaneButton.waitToExist(timeout: 10))
        generalPaneButton.click()

        let checkToggle = app.checkBoxes["automatic-update-check-toggle"].firstMatch
        XCTAssertTrue(checkToggle.waitToExist(timeout: 10))

        let installToggle = app.checkBoxes["automatic-update-install-toggle"].firstMatch
        XCTAssertTrue(installToggle.waitToExist(timeout: 10))

        let frequency = app.popUpButtons["update-check-frequency-picker"].firstMatch
        XCTAssertTrue(frequency.waitToExist(timeout: 10))
    }

    func testCheckFrequencyOffersDailyAndWeekly() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let settingsMenuItem = app.menuBars.menuItems["Settings…"]
        XCTAssertTrue(settingsMenuItem.waitToExist(timeout: 10))
        settingsMenuItem.click()

        let generalPaneButton = app.toolbars.buttons["General"]
        XCTAssertTrue(generalPaneButton.waitToExist(timeout: 10))
        generalPaneButton.click()

        let frequency = app.popUpButtons["update-check-frequency-picker"].firstMatch
        XCTAssertTrue(frequency.waitToExist(timeout: 10))

        frequency.click()
        XCTAssertTrue(app.menuItems["Daily"].waitToExist(timeout: 10))
        XCTAssertTrue(app.menuItems["Weekly"].exists)

        // Dismissed rather than chosen: selecting an item would write updateCheckInterval into the
        // machine's real Sparkle domain, which nothing in the suite can put back.
        app.typeKey(.escape, modifierFlags: [])
    }
}
