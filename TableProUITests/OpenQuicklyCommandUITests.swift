import XCTest

final class OpenQuicklyCommandUITests: UITestCase {
    /// Escape dismisses the panel, and it has to work through a real key press rather than through
    /// the delegate hook a unit test can call, because the whole failure lives above that hook.
    func testEscapeDismissesTheOpenQuicklyPanel() throws {
        let app = try launchWithSampleDatabase()
        XCTAssertTrue(
            app.windows.firstMatch.tables.matching(identifier: "data-grid").firstMatch
                .waitForExistence(timeout: 30)
        )
        app.activate()

        app.typeKey("o", modifierFlags: [.command, .shift])
        let searchField = switcherPanel(in: app).textFields["quick-switcher-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 15))

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            searchField.waitForNonExistence(timeout: 5),
            "Escape on an empty field must dismiss the panel"
        )
    }

    /// The two-step Escape shipped as #1490: the first clears a typed query, the second dismisses.
    func testEscapeClearsTheQueryThenDismissesThePanel() throws {
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

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (searchField.value as? String ?? "").isEmpty },
            "The first Escape clears the query"
        )
        XCTAssertTrue(searchField.exists, "The first Escape must not dismiss the panel")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            searchField.waitForNonExistence(timeout: 5),
            "The second Escape dismisses the panel"
        )
    }

    /// Every scope stays pickable with the mouse at all times. The scope controls used to be
    /// removed from the view tree by `if !showsResultSurface`, so a single Recent row, which is the
    /// panel's first frame on any connection with history, left four of the five scopes with no
    /// mouse affordance at all. Typing is the state that has to be asserted, because that is the
    /// state the old panel could never show them in.
    func testEveryScopeStaysReachableWhileTyping() throws {
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

        for scope in ["all", "tables", "containers", "queries", "connections"] {
            let chip = panel.buttons["quick-switcher-scope-\(scope)"]
            XCTAssertTrue(chip.waitForExistence(timeout: 5), "\(scope) chip missing on an empty query")
        }

        /// The panel is a fresh view model every time, so it always opens in All. Anything else
        /// means a stale scope survived a presentation, and the cross-connection scopes go and load
        /// every other connection's catalog on open.
        XCTAssertTrue(
            panel.buttons["quick-switcher-scope-all"].isSelected,
            "The panel opens in the All scope"
        )

        searchField.typeText("a")
        XCTAssertTrue(panel.buttons["Album"].waitForExistence(timeout: 10))

        for scope in ["all", "tables", "containers", "queries", "connections"] {
            let chip = panel.buttons["quick-switcher-scope-\(scope)"]
            XCTAssertTrue(
                waitUntilHittable(chip, timeout: 5),
                "\(scope) chip must stay clickable once results are listed"
            )
        }
    }

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
