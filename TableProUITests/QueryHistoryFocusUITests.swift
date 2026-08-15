import XCTest

final class QueryHistoryFocusUITests: UITestCase {
    /// Selecting a row is not activating it. Arrowing through a results list is how a history gets
    /// read, so the keyboard has to stay where the user put it until they ask for the query.
    func testArrowKeysKeepMovingThroughTheListAfterClickingARow() throws {
        let app = try launchWithSampleDatabase()
        runQueries(in: app, ["SELECT * FROM Genre;", "SELECT * FROM Album;", "SELECT * FROM Artist;"])

        let editor = app.windows.firstMatch.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let editorBeforeClick = editor.value as? String ?? ""

        let list = showHistoryDrawer(in: app)

        /// The drawer animates open, and a row frame read while it is still laying out puts the
        /// click somewhere the row has left. Both panes existing is what says the drawer is up.
        let detail = app.windows.firstMatch.descendants(matching: .any)
            .matching(identifier: "query-history-detail").firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 10))

        // Row 0 is the "Today" section header, so the first entry is row 1.
        let rows = list.tableRows
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 10), "The drawer must list the queries just run")
        rows.element(boundBy: 1).click()

        let preview = app.textViews["query-history-detail-query"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let previewAfterClick = preview.value as? String ?? ""
        XCTAssertFalse(previewAfterClick.isEmpty, "Clicking a row must show that row in the preview")

        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (preview.value as? String ?? "") != previewAfterClick },
            "Down arrow after clicking a row must move to the next entry"
        )

        let editorAfterTyping = editor.value as? String ?? ""
        XCTAssertEqual(
            editorAfterTyping,
            editorBeforeClick,
            "Arrowing through history must not type into the editor"
        )
    }

    @discardableResult
    private func showHistoryDrawer(in app: XCUIApplication) -> XCUIElement {
        app.typeKey("y", modifierFlags: .command)
        let list = app.windows.firstMatch.tables.matching(identifier: "query-history-list").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10), "Cmd+Y must show the query history drawer")
        return list
    }

    private func runQueries(in app: XCUIApplication, _ queries: [String]) {
        for query in queries {
            app.typeKey("t", modifierFlags: .command)
            let editor = app.windows.firstMatch.textViews.firstMatch
            XCTAssertTrue(editor.waitForExistence(timeout: 10))
            app.typeText(query)
            app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: .command)
            _ = app.windows.firstMatch.tables.matching(identifier: "data-grid").firstMatch
                .waitForExistence(timeout: 15)
        }
    }

    private func waitForPredicate(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        return condition()
    }
}
