import XCTest

final class OpenQuicklyCommandUITests: UITestCase {
    // A segment has no identifier of its own; `containers` is titled Databases.
    private static let scopeTitles = ["All", "Tables", "Databases", "Queries", "Connections"]

    func testOpenQuicklyFindsScopesAndOpensATable() throws {
        let launch = try launchWithFixture()
        let app = launch.app
        let window = launch.window

        app.typeShortcut(.openQuickly)
        let panel = switcherPanel(in: app)
        let searchField = panel.textFields["quick-switcher-search-field"]
        XCTAssertTrue(searchField.waitToExist(timeout: 15), "Cmd+Shift+O must open the panel")

        // The scopes used to leave the view tree once a result was listed, so they are checked while typing.
        let scopes = panel.radioGroups["quick-switcher-scope-picker"].firstMatch
        XCTAssertTrue(scopes.waitToExist(timeout: 10))
        XCTAssertTrue(isSelected(scopes.radioButtons["All"]), "The panel opens in the All scope")
        searchField.typeText("a")
        XCTAssertTrue(panel.buttons["album"].waitToExist(timeout: 10), "Typing must list matching tables")
        for title in Self.scopeTitles {
            XCTAssertTrue(
                waitUntilHittable(scopes.radioButtons[title], timeout: 5),
                "The \(title) scope must stay clickable once results are listed"
            )
        }

        scopes.radioButtons["Tables"].click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { self.isSelected(scopes.radioButtons["Tables"]) })
        // Typed at the application: `typeText` on the field would focus it first and hide a lost focus.
        app.typeText("lbum")
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (searchField.value as? String) == "album" },
            "A scope click must leave the keyboard in the search field"
        )

        // #1490: the first Escape clears a typed query, the second dismisses.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { ((searchField.value as? String) ?? "").isEmpty },
            "The first Escape clears the query"
        )
        XCTAssertTrue(searchField.exists, "The first Escape must not dismiss the panel")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5), "The second Escape dismisses the panel")

        app.typeShortcut(.openQuickly)
        XCTAssertTrue(searchField.waitToExist(timeout: 15))
        XCTAssertTrue(
            isSelected(scopes.radioButtons["All"]),
            "A reopened panel must not inherit the scope the last one was left in"
        )
        XCTAssertTrue(hint("Escape closes Open Quickly", in: panel).waitToExist(timeout: 5))
        // The field editor branches on the raw string, so spaces alone are still something to clear.
        searchField.typeText(" ")
        XCTAssertTrue(
            hint("Escape clears the search text", in: panel).waitToExist(timeout: 5),
            "A whitespace-only query still has something to clear, so the hint must say so"
        )
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitForPredicate(timeout: 5) { ((searchField.value as? String) ?? "").isEmpty })
        XCTAssertTrue(searchField.exists, "Escape clears the spaces, it does not dismiss")

        searchField.typeText("album")
        XCTAssertTrue(panel.buttons["album"].waitToExist(timeout: 10))
        searchField.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5), "Cmd+Return must commit and close the panel")
        XCTAssertTrue(editorTab(titled: "album", in: window).waitToExist(timeout: 10), "Cmd+Return opens a new tab")

        app.typeShortcut(.openQuickly)
        XCTAssertTrue(searchField.waitToExist(timeout: 10))
        searchField.typeText("artist")
        XCTAssertTrue(panel.buttons["artist"].waitToExist(timeout: 10))
        searchField.typeKey(.return, modifierFlags: .option)
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5))
        XCTAssertTrue(editorTab(titled: "artist", in: window).waitToExist(timeout: 10), "Option+Return opens a new tab")
        XCTAssertTrue(editorTab(titled: "album", in: window).exists, "The second open must keep the first tab")
        XCTAssertEqual(app.children(matching: .window).count, 1, "Both open in this window, not a new one")
    }

    // A floating panel reports as a dialog, and an app-rooted search walks every window's tree.
    private func switcherPanel(in app: XCUIApplication) -> XCUIElement {
        app.children(matching: .any).matching(identifier: "quick-switcher-panel").firstMatch
    }

    // A segment carries its selection in its value, 1 or 0; `isSelected` and the group's value read nothing.
    private func isSelected(_ segment: XCUIElement) -> Bool {
        (segment.value as? NSNumber)?.intValue == 1
    }

    // The footer is one element whose label is the Escape promise.
    private func hint(_ label: String, in panel: XCUIElement) -> XCUIElement {
        panel.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
}
