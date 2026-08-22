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
                .waitToExist(timeout: 30)
        )

        /// The switcher is a floating panel, and on the CI runner the shortcut produced nothing
        /// while the grid was loaded and focused. Activating first makes the app frontmost before
        /// the key goes out, which is the one difference between here and a developer's machine.
        app.activate()
        app.typeKey("o", modifierFlags: [.command, .shift])
        let panel = switcherPanel(in: app)
        let searchField = panel.textFields["quick-switcher-search-field"]
        XCTAssertTrue(searchField.waitToExist(timeout: 15))

        /// The scope chips are present in every scope now, so a chip's existence no longer says the
        /// key press landed. The grouped connection header below is what proves the scope changed.
        app.typeKey("5", modifierFlags: .command)
        XCTAssertTrue(panel.staticTexts["Chinook (Sample)"].waitToExist(timeout: 15))
        XCTAssertTrue(panel.buttons["Track"].waitToExist(timeout: 5))

        searchField.typeText("track")
        XCTAssertTrue(panel.buttons["Track"].waitToExist(timeout: 5))

        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeText("missing-object-name")
        XCTAssertTrue(panel.staticTexts["No results for \"missing-object-name\""].waitToExist(timeout: 5))

        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeText("track")
        searchField.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5))
        /// Every open connection lives in one window, so opening an object adds a tab rather than a
        /// window, and the window retitles to the tab it selected. The strip stays hidden while the
        /// connection holds a single tab, so the title is all there is to assert on here.
        let trackWindow = app.children(matching: .window)
            .matching(NSPredicate(format: "title BEGINSWITH %@", "Track")).firstMatch
        XCTAssertTrue(trackWindow.waitToExist(timeout: 10))
        XCTAssertEqual(app.children(matching: .window).count, 1)

        app.typeKey("o", modifierFlags: [.command, .shift])
        XCTAssertTrue(searchField.waitToExist(timeout: 5))
        app.typeKey("5", modifierFlags: .command)
        searchField.typeText("invoice")
        /// The panel has to have ranked Invoice before Return is sent. A new query used to leave the
        /// previously highlighted row selected whenever it still matched, and in this scope every
        /// subtitle carries the connection path, so Return committed the row typed before it.
        XCTAssertTrue(panel.buttons["Invoice"].waitToExist(timeout: 10))
        searchField.typeKey(.return, modifierFlags: .option)
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5))
        /// Option+Return opens beside the tab you were on instead of replacing it, which is the one
        /// thing that separates it from a plain Return. The second tab is also what brings the strip
        /// out of hiding, so both tabs are assertable from here and neither was before.
        XCTAssertTrue(tab(in: app, named: "Invoice").waitToExist(timeout: 10))
        XCTAssertTrue(tab(in: app, named: "Track").exists)
        XCTAssertEqual(app.children(matching: .window).count, 1)

        app.typeKey("o", modifierFlags: [.command, .shift])
        XCTAssertTrue(searchField.waitToExist(timeout: 5))
        searchField.typeText("dismiss-me")
        searchField.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(searchField.waitToExist(timeout: 5), "The first Escape clears the query, it does not dismiss")
        XCTAssertEqual(searchField.value as? String, "")
        searchField.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5))
    }

    func testQueriesScopeSearchesHistoryAndOpensANewTab() throws {
        let app = try launchWithSampleDatabase()

        app.typeKey("t", modifierFlags: .command)
        let queryEditor = editorTextView(in: app)
        XCTAssertTrue(queryEditor.waitToExist(timeout: 10))
        let query = "SELECT 42 AS cross_connection_probe;"
        queryEditor.click()
        app.typeText(query)
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(
            app.windows.firstMatch.tables.matching(identifier: "data-grid").firstMatch
                .waitToExist(timeout: 15)
        )
        queryEditor.click()
        queryEditor.typeKey("a", modifierFlags: .command)
        queryEditor.typeText("SELECT 0;")

        app.typeKey("o", modifierFlags: [.command, .shift])
        let panel = switcherPanel(in: app)
        let searchField = panel.textFields["quick-switcher-search-field"]
        XCTAssertTrue(searchField.waitToExist(timeout: 10))
        /// The history result below is what proves Cmd+4 landed; the chip is always present now.
        app.typeKey("4", modifierFlags: .command)

        searchField.typeText("cross_connection_probe")
        let historyResult = panel.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "cross_connection_probe")
        ).firstMatch
        XCTAssertTrue(historyResult.waitToExist(timeout: 10))

        searchField.typeKey(.return, modifierFlags: .option)
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5))
        /// The editor's accessibility identifier is set on the SwiftUI wrapper and does not reach
        /// the text view itself, so the query it carries is what identifies the tab that opened.
        let openedEditor = app.textViews
            .matching(NSPredicate(format: "value CONTAINS %@", "cross_connection_probe"))
            .firstMatch
        XCTAssertTrue(openedEditor.waitToExist(timeout: 10))
    }

    /// Every lookup inside the switcher goes through here. Rooted at the application the same
    /// queries walk the whole accessibility tree, and with a data grid loaded in the main window
    /// one existence check overran XCTest's own four second evaluation watchdog and had to be
    /// retried: this test alone spent seven minutes of the job's budget on that.
    ///
    /// `children` rather than `descendants` keeps resolving the panel shallow, because the panel is
    /// a direct child of the application element and searching the descendants for it costs the
    /// walk all over again. The type stays `.any` because AppKit gives a floating panel the
    /// `AXDialog` subrole, which XCUITest reports as `Dialog` and not as `Window`.
    private func switcherPanel(in app: XCUIApplication) -> XCUIElement {
        app.children(matching: .any).matching(identifier: "quick-switcher-panel").firstMatch
    }

    private func tab(in app: XCUIApplication, named name: String) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "editor-tab", name)
        ).firstMatch
    }
}
