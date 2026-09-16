import XCTest

/// Updates check and install on their own, so the two toggles that reverse that are the whole of
/// the user's consent and the pane has to offer both. The frequency picker that used to sit between
/// them is gone: it reversed nothing, it only slowed a security fix down, and Sparkle documents
/// `SUScheduledCheckInterval` in Info.plist as where that value belongs.
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
        XCTAssertTrue(app.buttons["check-for-updates-button"].firstMatch.waitToExist(timeout: 10))
    }

    /// The pane used to reach the changelog in a browser while Help and the welcome window both
    /// opened the in-app window, so one label did two different things by entry point.
    ///
    /// The assertion has to be the window, not the element's role: `.buttonStyle(.link)` publishes
    /// the control as a Link whatever its action does, which is also how the welcome window's copy
    /// reads. Only clicking it tells the two apart.
    func testWhatsNewOpensTheInAppWindow() throws {
        let app = try launchApp()
        openGeneralSettings(in: app)

        let whatsNew = app.links["whats-new-link"].firstMatch
        XCTAssertTrue(whatsNew.waitToExist(timeout: 10))
        whatsNew.click()

        XCTAssertTrue(
            app.windows["What's New"].waitToExist(timeout: 10),
            "Settings must open the same window as Help > What's New, not a browser tab"
        )
    }

    /// The row every comparable Mac app has and this pane did not: without it the only answer to
    /// "am I current" is to press the button and wait.
    func testLastCheckedRowIsShown() throws {
        let app = try launchApp(arguments: ["-SUEnableAutomaticChecks", "NO"])
        openGeneralSettings(in: app)

        let lastChecked = app.staticTexts["last-update-check-label"].firstMatch
        XCTAssertTrue(lastChecked.waitToExist(timeout: 10))

        // A SwiftUI Text in a Form row publishes its string as the element's value, not its label,
        // the way every other static text in this pane does. Both are read because the runner's
        // accessibility tree differs from this machine's.
        let shown = (lastChecked.value as? String) ?? lastChecked.label
        XCTAssertTrue(shown.contains("Last checked"), "Expected a last-checked line, got \(shown)")
    }

    /// The install toggle follows `allowsAutomaticUpdates`, which Sparkle derives from
    /// `automaticallyChecksForUpdates` when `SUAllowsAutomaticUpdates` is unset. With checks pinned
    /// off it is not merely dimmed: `setAutomaticallyDownloadsUpdates` returns without writing.
    func testInstallToggleFollowsTheCheckToggle() throws {
        let app = try launchApp(arguments: ["-SUEnableAutomaticChecks", "NO"])
        openGeneralSettings(in: app)

        let installToggle = app.switches["automatic-update-install-toggle"].firstMatch
        XCTAssertTrue(installToggle.waitToExist(timeout: 10))
        XCTAssertFalse(installToggle.isEnabled, "Automatic installs cannot be on while checks are off")
    }

    /// A started updater in a test launch asks for permission on the runner's second launch, and
    /// that prompt took the key window from thirteen tests in eleven unrelated suites. The updater
    /// now starts from `AppDelegate.runPostLaunchActivationIfNeeded()`, which returns early for an
    /// isolated launch, so Check for Updates stays disabled. Automatic checks are pinned off so a
    /// started updater would neither prompt nor begin a background check, either of which would
    /// disable the button for a while and let this pass without proving anything.
    func testATestLaunchNeverStartsTheUpdater() throws {
        let app = try launchApp(arguments: ["-SUEnableAutomaticChecks", "NO"])
        openGeneralSettings(in: app)

        let checkNow = app.windows["settings"].buttons["check-for-updates-button"].firstMatch
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
