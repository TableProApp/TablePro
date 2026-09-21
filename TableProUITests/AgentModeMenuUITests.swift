import XCTest

/// The mode is asserted through the menu bar, which reaches it at any window width.
///
/// The toolbar has no mode control. Browse and Agent are chosen from View > Mode, from ⌥⇧⌘A, and
/// from the Mode submenu of the toolbar's Actions pull-down, which is filled from the same enum as
/// View > Mode so the two cannot offer different modes. The Actions pull-down can sit in the
/// toolbar's overflow menu on a narrow window, the runner's included, and the menu bar cannot.
final class AgentModeMenuUITests: UITestCase {
    private func openViewModeMenu(in app: XCUIApplication) -> XCUIElement {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 10))
        menuBar.menuBarItems["View"].click()
        menuBar.menuItems["Mode"].click()
        return menuBar.menuItems["Mode"]
    }

    func testModeIsReachableFromTheViewMenu() throws {
        let app = try launchApp()

        _ = openViewModeMenu(in: app)
        let menuBar = app.menuBars.firstMatch

        XCTAssertTrue(
            menuBar.menuItems["Browse"].waitToExist(timeout: 10),
            "View > Mode must offer Browse"
        )
        XCTAssertTrue(
            menuBar.menuItems["Agent"].exists,
            "View > Mode must offer Agent"
        )
    }

    /// With no mode control in the toolbar, the chord is the one-step way to switch, so the menu has
    /// to carry it where a user looking for it will find it.
    func testToggleAgentModeCarriesItsShortcut() throws {
        let app = try launchApp()

        _ = openViewModeMenu(in: app)
        let toggle = app.menuBars.firstMatch.menuItems["Toggle Agent Mode"]

        XCTAssertTrue(
            toggle.waitToExist(timeout: 10),
            "One chord toggles the mode; naming one arm of the pair would leave the other unreachable"
        )
    }

    /// Browse and Agent are a radio pair, so they are never both ticked.
    ///
    /// Not "exactly one": with no connection window there is no `MainSplitViewController` in the
    /// responder chain, so nothing validates the pair and neither carries a tick. That is the state
    /// a fresh launch is in, and asserting on one being ticked would be asserting on the launch
    /// having opened a connection.
    func testTheModePairIsNeverBothTicked() throws {
        let app = try launchApp()

        _ = openViewModeMenu(in: app)
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.menuItems["Browse"].waitToExist(timeout: 10))

        let ticked = [menuBar.menuItems["Browse"], menuBar.menuItems["Agent"]]
            .filter { $0.isSelected }
            .count
        XCTAssertLessThanOrEqual(ticked, 1, "Two arms of a radio pair cannot both carry the tick")
    }
}
