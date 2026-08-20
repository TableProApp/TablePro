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

        let scopes = scopePicker(in: panel)
        XCTAssertTrue(scopes.waitForExistence(timeout: 10))

        for title in Self.scopeTitles {
            XCTAssertTrue(
                scopes.radioButtons[title].waitForExistence(timeout: 5),
                "the \(title) segment is missing on an empty query"
            )
        }

        /// The panel is a fresh view model every time, so it always opens in All. Anything else
        /// means a stale scope survived a presentation, and the cross-connection scopes go and load
        /// every other connection's catalog on open.
        XCTAssertTrue(isSelected(scopes.radioButtons["All"]), "The panel opens in the All scope")

        searchField.typeText("a")
        XCTAssertTrue(panel.buttons["Album"].waitForExistence(timeout: 10))

        for title in Self.scopeTitles {
            XCTAssertTrue(
                waitUntilHittable(scopes.radioButtons[title], timeout: 5),
                "the \(title) segment must stay clickable once results are listed"
            )
        }

        /// Clicking a scope must not end typing. The search field claims first responder once when
        /// the panel opens and nothing re-claims it, so a control that took focus on click would
        /// leave the user unable to type without clicking back into the field.
        scopes.radioButtons["Tables"].click()
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { isSelected(scopes.radioButtons["Tables"]) },
            "Clicking a segment selects it"
        )
        /// Application-scoped on purpose. `XCUIElement.typeText` focuses its element first, so
        /// typing into the field would restore the focus this is trying to prove was never lost,
        /// and the assertion could not fail. Typing at the application goes wherever focus actually
        /// is, which is the question.
        app.typeText("l")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (searchField.value as? String ?? "") == "al" },
            "The search field still has keyboard focus after a scope click"
        )
    }

    /// A query of nothing but spaces still has something for Escape to clear, because the field
    /// editor branches on the raw string. The footer used to branch on the trimmed one, so it
    /// promised Close and then cleared.
    func testAWhitespaceQueryStillPromisesEscapeWillClear() throws {
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

        XCTAssertTrue(
            hint(in: panel, "Escape closes Open Quickly").waitForExistence(timeout: 5),
            "An empty field promises Escape closes the panel"
        )

        searchField.typeText(" ")
        XCTAssertTrue(
            hint(in: panel, "Escape clears the search text").waitForExistence(timeout: 5),
            "A whitespace-only query still has something to clear, so the hint must say so"
        )

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(searchField.exists, "That first Escape clears the space, it does not dismiss")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (searchField.value as? String ?? "").isEmpty }
        )
    }

    /// The footer is one accessibility element whose label is the Escape promise, so the promise is
    /// assertable without reading pixels.
    private func hint(in panel: XCUIElement, _ label: String) -> XCUIElement {
        panel.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", label)
        ).firstMatch
    }

    /// The five scope titles as the user sees them. Segments carry no accessibility identifier of
    /// their own, so a label is the only handle, and the `containers` case is titled "Databases".
    private static let scopeTitles = ["All", "Tables", "Databases", "Queries", "Connections"]

    private func scopePicker(in panel: XCUIElement) -> XCUIElement {
        panel.radioGroups["quick-switcher-scope-picker"].firstMatch
    }

    /// A segment carries its selection in its accessibility VALUE, 1 or 0, not in a selected trait
    /// and not in the group's value. Measured on the real control: every segment reports
    /// `AXSelected` as nil, and the group's `AXValue` is a reference to the selected child rather
    /// than its title, so both `isSelected` and `group.value` read as nothing.
    private func isSelected(_ segment: XCUIElement) -> Bool {
        (segment.value as? NSNumber)?.intValue == 1
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

        let openQuickly = app.menuBars.menuItems["Open Quickly…"]
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
