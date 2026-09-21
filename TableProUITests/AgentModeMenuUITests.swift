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

    /// The session lifecycle's only routes used to be the rail's two buttons and its context menu, so
    /// a user with the rail collapsed had none at all, and none of the four could be found by search
    /// or rebound. They are asserted on a fresh launch, where they are present and dim: the menu bar
    /// is built once at launch and carries every command the app has, whatever window is in front.
    func testFileSessionCarriesTheSessionLifecycle() throws {
        let app = try launchApp()
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 10))

        menuBar.menuBarItems["File"].click()
        menuBar.menuItems["Session"].click()

        for title in ["New Session", "Open Session", "Close Session", "Delete Session…"] {
            XCTAssertTrue(
                menuBar.menuItems[title].waitToExist(timeout: 10),
                "File > Session must offer \(title)"
            )
        }
    }

    /// The assistant's three conversation commands lived in the trailing pane's header menu, which
    /// Agent mode replaces with the result column, so entering the mode took them away outright.
    func testFileSessionCarriesTheConversationCommands() throws {
        let app = try launchApp()
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 10))

        menuBar.menuBarItems["File"].click()
        menuBar.menuItems["Session"].click()

        for title in ["New Conversation", "Conversation History", "Clear Recents…"] {
            XCTAssertTrue(
                menuBar.menuItems[title].waitToExist(timeout: 10),
                "File > Session must offer \(title)"
            )
        }
    }

    /// With no connection window in front there is no rail and no session, so every one of them is
    /// present and dim. A command lit over a window that cannot run it is the defect these items
    /// would otherwise introduce, since the menu bar is built once at launch for the whole app.
    func testTheSessionCommandsAreDimWithNoConnectionWindow() throws {
        let app = try launchApp()
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 10))

        menuBar.menuBarItems["File"].click()
        menuBar.menuItems["Session"].click()
        XCTAssertTrue(menuBar.menuItems["New Session"].waitToExist(timeout: 10))

        for title in ["New Session", "Open Session", "Close Session", "Delete Session…"] {
            XCTAssertFalse(
                menuBar.menuItems[title].isEnabled,
                "\(title) acts on a rail that no window is drawing"
            )
        }
    }
}
