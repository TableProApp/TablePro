import XCTest

/// Switching a connection window between Browse and Assistant, driven through **View > Mode**.
///
/// Not through the toolbar's segmented control, for two reasons that both came out of measurement.
/// XCUITest cannot work it: the group publishes as a radio group of radio buttons, and `click()` on
/// a segment leaves `isSelected` false and the window unchanged, because AppKit does not route a
/// synthetic click to a segment inside a toolbar item group. And the runner's screen is 1024x768,
/// so a window there is narrow enough that the control collapses into the toolbar's overflow menu
/// and the segments do not exist at all: an earlier version of this suite asserted on them and
/// failed on CI for that reason while passing on any real display.
///
/// The menu command has neither problem. It is what a keyboard user reaches for, it exists at every
/// window width, and a menu item is something XCUITest can actually click, which is what makes the
/// switch itself testable rather than only its chrome.
@MainActor
final class AssistantModeSwitchUITests: UITestCase {
    private func mainWindow(of app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.matching(NSPredicate(format: "identifier != %@", "welcome")).firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 60), "The sample database produced no window")
        return window
    }

    /// Walks View > Mode rather than typing a shortcut, because the command deliberately has none.
    private func chooseMode(_ title: String, in app: XCUIApplication) {
        let viewMenu = app.menuBars.menuBarItems["View"]
        XCTAssertTrue(viewMenu.waitToExist(timeout: 10), "The View menu must exist")
        viewMenu.click()

        let modeItem = app.menuBars.menuItems["Mode"]
        XCTAssertTrue(modeItem.waitToExist(timeout: 10), "View > Mode must exist")
        XCTAssertTrue(modeItem.waitToBeHittable(timeout: 10), "View > Mode must be reachable")
        modeItem.click()

        let item = app.menuBars.menuItems[title]
        XCTAssertTrue(item.waitToExist(timeout: 10), "View > Mode > \(title) must exist")
        XCTAssertTrue(item.waitToBeHittable(timeout: 10), "View > Mode > \(title) must be clickable")
        item.click()
    }

    /// No sample database. `MainMenuBuilder.install` runs in `applicationWillFinishLaunching`, so
    /// the menu exists before any connection does, and this case only asks whether the commands are
    /// there rather than what they do. Opening a database to read a menu is the expensive and
    /// flake-prone half of a UI test bought for nothing.
    func testTheModeCommandsAreInTheViewMenu() throws {
        let app = try launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitToExist(timeout: 10), "The app produced no window")

        app.menuBars.menuBarItems["View"].click()
        let modeItem = app.menuBars.menuItems["Mode"]
        XCTAssertTrue(modeItem.waitToExist(timeout: 10), "View > Mode must exist")
        modeItem.click()

        XCTAssertTrue(
            app.menuBars.menuItems["Browse"].waitToExist(timeout: 10),
            "View > Mode must offer Browse"
        )
        XCTAssertTrue(
            app.menuBars.menuItems["Assistant"].exists,
            "View > Mode must offer Assistant"
        )
    }

    /// Both directions in one launch.
    ///
    /// The object browser is what Browse mode puts in the sidebar and Assistant mode replaces with
    /// the session rail, so the outline going and coming back is the switch actually happening
    /// rather than a menu item merely being clickable. A window that cannot get back to its tables
    /// has stranded the user, so the return leg matters as much as the outbound one.
    ///
    /// One launch, not two. Opening the sample database is the most expensive and least reliable
    /// thing this suite does: it is the "sample database never finished opening" failure the
    /// repository already knows drifts from run to run, and splitting the round trip across two
    /// cases paid for it twice for one flow.
    func testSwitchingModeReplacesTheObjectBrowserAndBringsItBack() throws {
        let app = try launchWithSampleDatabase()
        let window = try mainWindow(of: app)

        /// The session rail's own section heading, not the object browser's contents.
        ///
        /// Two earlier shapes of this assertion were wrong for reasons worth keeping. Asking
        /// whether an outline exists is true in both modes: `AgentSessionRailView` is a `List` of
        /// `Section`s at `.listStyle(.sidebar)`, which XCUITest publishes as an outline exactly as
        /// the object browser is. Asking for a named table ties the test to whatever the sample
        /// database happens to contain and to how its sidebar is laid out on a fresh container.
        ///
        /// Switching to Assistant creates a session for the connection, so the rail always has a
        /// "This Connection" section and Browse mode never does. That is this branch's own string,
        /// independent of the data and of how either sidebar publishes its rows.
        let railHeading = window.staticTexts["This Connection"]

        XCTAssertFalse(railHeading.exists, "Browse mode must not show the session rail")

        chooseMode("Assistant", in: app)
        XCTAssertTrue(
            railHeading.waitToExist(timeout: 20),
            "Assistant mode must put the session rail where the object browser was"
        )

        chooseMode("Browse", in: app)
        XCTAssertTrue(
            UITestPoll.until(timeout: 20) { !railHeading.exists },
            "Returning to Browse must take the session rail away again"
        )
    }
}
