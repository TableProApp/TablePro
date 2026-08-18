import XCTest

final class OpenQuicklyCommandUITests: UITestCase {
    /// The command moved from the Database menu to the File menu and was renamed from
    /// "Quick Switcher..." to "Open Quickly...", so the menu path itself is the assertion.
    func testFileMenuOpensTheQuicklyPanel() throws {
        let app = try launchWithSampleDatabase()
        XCTAssertTrue(
            app.windows.firstMatch.tables.matching(identifier: "data-grid").firstMatch
                .waitForExistence(timeout: 30)
        )
        app.activate()

        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 10))
        fileMenu.click()

        let openQuickly = app.menuBars.menuItems["Open Quickly..."]
        XCTAssertTrue(openQuickly.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilHittable(openQuickly, timeout: 5))
        openQuickly.click()

        let searchField = switcherPanel(in: app).textFields["quick-switcher-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 15))

        XCTAssertFalse(
            app.menuBars.menuItems["Quick Switcher..."].exists,
            "The old Database menu item must not survive the move"
        )
    }

    /// Command+Return joins the Option+Return that already opened a result in a new tab. Both are
    /// asserted here so neither can be dropped without a failure.
    func testCommandReturnOpensTheResultInANewTab() throws {
        let app = try launchWithSampleDatabase()
        XCTAssertTrue(
            app.windows.firstMatch.tables.matching(identifier: "data-grid").firstMatch
                .waitForExistence(timeout: 30)
        )
        app.activate()

        app.typeKey("o", modifierFlags: [.command, .shift])
        let panel = switcherPanel(in: app)
        let searchField = panel.textFields["quick-switcher-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 15))

        searchField.typeText("album")
        XCTAssertTrue(panel.buttons["Album"].waitForExistence(timeout: 10))
        searchField.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5))

        /// A second tab is what brings the strip out of hiding, so both tabs become assertable.
        XCTAssertTrue(tab(in: app, named: "Album").waitForExistence(timeout: 10))
        XCTAssertEqual(app.children(matching: .window).count, 1)

        app.typeKey("o", modifierFlags: [.command, .shift])
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.typeText("artist")
        XCTAssertTrue(panel.buttons["Artist"].waitForExistence(timeout: 10))
        searchField.typeKey(.return, modifierFlags: .option)
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5))

        XCTAssertTrue(tab(in: app, named: "Artist").waitForExistence(timeout: 10))
        XCTAssertTrue(tab(in: app, named: "Album").exists)
        XCTAssertEqual(app.children(matching: .window).count, 1)
    }

    /// Scoped the same way `QuickSwitcherCrossConnectionUITests` scopes it: rooted at the
    /// application, the same query walks the whole accessibility tree and overruns XCTest's
    /// evaluation watchdog once a data grid is loaded. `.any` because AppKit gives a floating
    /// panel the `AXDialog` subrole, which XCUITest reports as Dialog rather than Window.
    private func switcherPanel(in app: XCUIApplication) -> XCUIElement {
        app.children(matching: .any).matching(identifier: "quick-switcher-panel").firstMatch
    }

    private func tab(in app: XCUIApplication, named name: String) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "editor-tab", name)
        ).firstMatch
    }
}
