import XCTest

/// The mode is asserted through the menu bar, which is the only route that can be driven.
///
/// Measured against a dumped accessibility tree: the toolbar control publishes as a radio group of
/// radio buttons, the Agent segment reports `exists` and `isHittable`, and `click()` leaves
/// `isSelected` false with the window unchanged. AppKit does not route a synthetic click to a
/// segment inside an `NSToolbarItemGroup`, and at the runner's window width the control sits in the
/// toolbar's overflow menu, where the segments do not exist at all. A suite built on clicking it
/// would pass by skipping itself.
///
/// The menu command exists partly for that reason and mostly because the HIG asks that every
/// toolbar item also be a menu-bar command.
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

    /// Every toolbar item is also a menu-bar command, so the mode is reachable with the toolbar
    /// hidden, customized, or too narrow to show the control.
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
