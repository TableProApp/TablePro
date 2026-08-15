import XCTest

final class QuickSwitcherCrossConnectionUITests: UITestCase {
    func testConnectionsScopeSearchesTheOpenSampleDatabase() throws {
        let app = try launchWithSampleDatabase()
        /// The sample opens a table tab, and the switcher shortcut is sent to an app that is still
        /// connecting and loading if the test does not wait for that to finish. The grid appearing
        /// is the signal, and waiting for the window alone is not: the window exists immediately.
        /// This test passed locally and lost the keystroke on the slower CI runner without it.
        XCTAssertTrue(
            app.windows.firstMatch.tables.matching(identifier: "data-grid").firstMatch
                .waitForExistence(timeout: 30)
        )

        /// The switcher is a floating panel, and on the CI runner the shortcut produced nothing
        /// while the grid was loaded and focused. Activating first makes the app frontmost before
        /// the key goes out, which is the one difference between here and a developer's machine.
        app.activate()
        app.typeKey("o", modifierFlags: [.command, .shift])
        let searchField = app.textFields["quick-switcher-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 15))

        app.typeKey("5", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Connections"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Chinook (Sample)"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Track"].waitForExistence(timeout: 5))

        searchField.typeText("track")
        XCTAssertTrue(app.buttons["Track"].waitForExistence(timeout: 5))

        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeText("missing-object-name")
        XCTAssertTrue(app.staticTexts["No results for \"missing-object-name\""].waitForExistence(timeout: 5))

        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeText("track")
        searchField.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5))
        /// Every open connection lives in one window, so opening an object adds a tab rather than a
        /// window, and the window retitles to the tab it selected. The strip stays hidden while the
        /// connection holds a single tab, so the title is all there is to assert on here.
        let trackWindow = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", "Track")).firstMatch
        XCTAssertTrue(trackWindow.waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1)

        app.typeKey("o", modifierFlags: [.command, .shift])
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        app.typeKey("5", modifierFlags: .command)
        searchField.typeText("invoice")
        /// The panel has to have ranked Invoice before Return is sent. A new query used to leave the
        /// previously highlighted row selected whenever it still matched, and in this scope every
        /// subtitle carries the connection path, so Return committed the row typed before it.
        XCTAssertTrue(app.buttons["Invoice"].waitForExistence(timeout: 10))
        searchField.typeKey(.return, modifierFlags: .option)
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5))
        /// Option+Return opens beside the tab you were on instead of replacing it, which is the one
        /// thing that separates it from a plain Return. The second tab is also what brings the strip
        /// out of hiding, so both tabs are assertable from here and neither was before.
        XCTAssertTrue(tab(in: app, named: "Invoice").waitForExistence(timeout: 10))
        XCTAssertTrue(tab(in: app, named: "Track").exists)
        XCTAssertEqual(app.windows.count, 1)

        app.typeKey("o", modifierFlags: [.command, .shift])
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.typeText("dismiss-me")
        searchField.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "The first Escape clears the query, it does not dismiss")
        XCTAssertEqual(searchField.value as? String, "")
        searchField.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5))
    }

    func testQueriesScopeSearchesHistoryAndOpensANewTab() throws {
        let app = try launchWithSampleDatabase()

        app.typeKey("t", modifierFlags: .command)
        let queryEditor = editorTextView(in: app)
        XCTAssertTrue(queryEditor.waitForExistence(timeout: 10))
        let query = "SELECT 42 AS cross_connection_probe;"
        queryEditor.click()
        app.typeText(query)
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(
            app.windows.firstMatch.tables.matching(identifier: "data-grid").firstMatch
                .waitForExistence(timeout: 15)
        )
        queryEditor.click()
        queryEditor.typeKey("a", modifierFlags: .command)
        queryEditor.typeText("SELECT 0;")

        app.typeKey("o", modifierFlags: [.command, .shift])
        let searchField = app.textFields["quick-switcher-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        app.typeKey("4", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Queries"].waitForExistence(timeout: 5))

        searchField.typeText("cross_connection_probe")
        let historyResult = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "cross_connection_probe")
        ).firstMatch
        XCTAssertTrue(historyResult.waitForExistence(timeout: 10))

        searchField.typeKey(.return, modifierFlags: .option)
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5))
        /// The editor's accessibility identifier is set on the SwiftUI wrapper and does not reach
        /// the text view itself, so the query it carries is what identifies the tab that opened.
        let openedEditor = app.textViews
            .matching(NSPredicate(format: "value CONTAINS %@", "cross_connection_probe"))
            .firstMatch
        XCTAssertTrue(openedEditor.waitForExistence(timeout: 10))
    }

    private func tab(in app: XCUIApplication, named name: String) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "editor-tab", name)
        ).firstMatch
    }

    private func editorTextView(in app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch
        let identified = window.textViews.matching(identifier: "sql-editor-textview").firstMatch
        if identified.exists {
            return identified
        }
        return window.textViews.firstMatch
    }
}
