import XCTest

/// Updates install in the background from this release on, so the two controls that reverse that
/// and the one that slows it down are the whole of the user's consent. A pane that does not offer
/// them is a default flipped with no way back.
///
/// Nothing here writes an update preference. Sparkle reads and writes them through `SUHost`, which
/// uses the standard user defaults for the main bundle, so a click on one of these controls lands
/// in the real `com.TablePro` domain rather than the UI-test suite, and the runner is sandboxed
/// away from clearing it again. A case that flipped a toggle would change the update behaviour of
/// the machine it ran on and leak into every later case. A launch argument such as
/// `-SUEnableAutomaticChecks YES` lands in the argument domain instead, which is read first and
/// never written, so that is how a case pins the state a control depends on.
final class SoftwareUpdateSettingsUITests: UITestCase {
    func testSoftwareUpdateControlsAreOffered() throws {
        let app = try launchApp()
        openGeneralSettings(in: app)

        XCTAssertTrue(app.switches["automatic-update-check-toggle"].firstMatch.waitToExist(timeout: 10))
        XCTAssertTrue(app.switches["automatic-update-install-toggle"].firstMatch.waitToExist(timeout: 10))
        XCTAssertTrue(app.popUpButtons["update-check-frequency-picker"].firstMatch.waitToExist(timeout: 10))
    }

    func testCheckFrequencyOffersDailyAndWeekly() throws {
        let app = try launchApp(arguments: ["-SUEnableAutomaticChecks", "YES"])
        openGeneralSettings(in: app)

        let frequency = app.popUpButtons["update-check-frequency-picker"].firstMatch
        XCTAssertTrue(frequency.waitToExist(timeout: 10))
        XCTAssertTrue(frequency.isEnabled, "The frequency applies only while automatic checks are on")

        frequency.click()
        XCTAssertTrue(app.menuItems["Daily"].waitToExist(timeout: 10))
        XCTAssertTrue(app.menuItems["Weekly"].exists)

        // Dismissed rather than chosen: selecting an item would write updateCheckInterval into the
        // machine's real Sparkle domain, which nothing in the suite can put back.
        app.typeKey(.escape, modifierFlags: [])
    }

    /// A started updater in a test launch asks for permission on the runner's second launch, and
    /// that prompt took the key window from thirteen tests in eleven unrelated suites. Check for
    /// Updates is enabled by Sparkle's `startUpdater`. Automatic checks are pinned off so a started
    /// updater neither prompts nor begins a background check, either of which would disable the
    /// button for a while and let this pass without proving anything.
    func testATestLaunchNeverStartsTheUpdater() throws {
        let app = try launchApp(arguments: ["-SUEnableAutomaticChecks", "NO"])
        openGeneralSettings(in: app)

        let checkNow = app.windows["settings"].buttons["Check for Updates…"].firstMatch
        XCTAssertTrue(checkNow.waitToExist(timeout: 10))
        XCTAssertFalse(checkNow.isEnabled, "A UI test launch must not start Sparkle")
    }

    private func openGeneralSettings(in app: XCUIApplication) {
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10))

        let settingsMenuItem = app.menuBars.menuItems["Settings…"]
        XCTAssertTrue(settingsMenuItem.waitToExist(timeout: 10))
        settingsMenuItem.click()

        let generalPaneButton = app.toolbars.buttons["General"]
        XCTAssertTrue(generalPaneButton.waitToExist(timeout: 10))
        generalPaneButton.click()
    }
}
