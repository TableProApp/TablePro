import XCTest

/// The test sandbox carries no license, so this run sees exactly what an unlicensed user sees:
/// `Compare & Sync Databases…` stays enabled, because a Pro feature the user can buy has to be
/// discoverable, and choosing it explains the gate instead of opening the window.
///
/// The suite this replaces asserted on the window itself, on a `popUpButtons` value of
/// "Choose a connection" and on a Compare button, none of which exist: the window never opens
/// without a license, and the rebuilt toolbar spells its placeholder "Choose Source". It could not
/// pass on any machine. The window's own contract now lives in `CompareSyncSessionTests` and
/// `DatabaseEndpointTests`, which reach it without a license.
final class CompareSyncUITests: UITestCase {
    private let licenseAlertMessage = "Compare & Sync requires a license"

    private func openCompareSyncMenuItem(in app: XCUIApplication) -> XCUIElement {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 10))
        menuBar.menuBarItems["Database"].click()
        menuBar.menuItems["Compare"].click()
        return menuBar.menuItems["Compare & Sync Databases…"]
    }

    func testCompareSyncIsReachableFromTheDatabaseMenu() throws {
        let app = try launchApp()

        let item = openCompareSyncMenuItem(in: app)
        XCTAssertTrue(
            item.waitToExist(timeout: 10),
            "Compare & Sync must be reachable from Database > Compare"
        )
        XCTAssertTrue(
            item.isEnabled,
            "A feature the user can buy stays enabled, so choosing it can explain what it needs"
        )
    }

    /// The gate is enforced when the window is asked for rather than when the menu is validated, so
    /// this is the only place the refusal can be observed.
    func testChoosingItWithoutALicenseExplainsTheGateInsteadOfOpeningTheWindow() throws {
        let app = try launchApp()

        let item = openCompareSyncMenuItem(in: app)
        XCTAssertTrue(item.waitToExist(timeout: 10))
        item.click()

        let message = app.staticTexts[licenseAlertMessage]
        XCTAssertTrue(
            message.waitToExist(timeout: 10),
            "An unlicensed run must say what Compare & Sync needs"
        )
        XCTAssertFalse(
            app.windows["Compare & Sync"].exists,
            "Nothing may open the comparison window without a license"
        )

        let dialog = app.dialogs.firstMatch
        guard dialog.exists, dialog.buttons["Cancel"].exists else { return }
        dialog.buttons["Cancel"].click()
    }
}
