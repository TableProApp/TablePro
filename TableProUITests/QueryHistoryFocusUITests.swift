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

        /// The guard here used to be the detail pane existing, which proves nothing: that pane
        /// publishes its identifier in the empty state too, so it was up before a single row was.
        /// The list is still filling as the drawer opens, and the entry at a given index changes
        /// as rows arrive, so a settled row count is what says there is a row worth clicking.
        let rows = list.tableRows
        let rowCount = waitForStableCount(of: rows, timeout: 10)
        XCTAssertGreaterThan(rowCount, 1, "The drawer must list the queries just run")

        // Row 0 is the "Today" section header, so the first entry is row 1.
        let row = rows.element(boundBy: 1)
        row.click()

        /// The selection is asserted before the preview so a failure says which half broke. The
        /// preview is the detail pane rendering a selected row, so a missing preview on its own
        /// cannot tell a click that never landed from a pane that never drew.
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { row.isSelected },
            "Clicking a row must select it"
        )

        let preview = app.textViews["query-history-detail-query"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "A selected row must show in the preview")
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
}
