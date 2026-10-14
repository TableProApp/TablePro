import XCTest

final class QueryHistoryPanelUITests: UITestCase {
    private static let queries = [
        ("SELECT name FROM genre;", "Rock"),
        ("SELECT title FROM album;", "North"),
        ("SELECT name FROM artist;", "Ada"),
    ]

    // Sending a query back to the editor is why the drawer exists, and every route to it once shipped dead.
    func testTheHistoryDrawerLoadsAnEntryIntoTheEditor() throws {
        let launch = try launchWithFixture()
        let app = launch.app
        let window = launch.window

        let grid = dataGrid(in: window)
        for (sql, firstValue) in Self.queries {
            typeQuery(sql, in: window)
            app.typeShortcut(.runQuery)
            XCTAssertTrue(gridCell(showing: firstValue, in: grid).waitToExist(timeout: 15), "\(sql) must run")
        }

        app.typeShortcut(.newTab)
        let editor = queryEditor(in: window)
        XCTAssertTrue(waitForEditorText(editor) { $0.isEmpty }, "Cmd+T must open an empty query tab")
        let tabCount = editorTabs(in: window).count

        app.typeShortcut(.toggleHistory)
        let list = window.tables.matching(identifier: "query-history-list").firstMatch
        XCTAssertTrue(list.waitToExist(timeout: 10), "Cmd+Y must show the query history drawer")
        // Row 0 is the day's section header.
        XCTAssertTrue(list.tableRows.element(boundBy: 3).waitToExist(timeout: 10), "The drawer must list all three runs")

        XCTAssertTrue(
            window.searchFields.matching(identifier: "query-history-search-field").firstMatch.exists,
            "The drawer must own a search field"
        )
        XCTAssertTrue(
            window.searchFields.matching(identifier: "sidebar-filter").firstMatch.exists,
            "The sidebar filter must keep its own identifier"
        )
        let scope = window.popUpButtons.matching(identifier: "query-history-scope-picker").firstMatch
        XCTAssertTrue(scope.waitToExist(timeout: 10), "The drawer must expose the connection scope")
        XCTAssertEqual(scope.value as? String, "This Connection", "History starts scoped to this connection")
        XCTAssertTrue(
            window.popUpButtons.matching(identifier: "query-history-date-picker").firstMatch.exists,
            "The drawer must expose the date range"
        )

        let newest = list.tableRows.element(boundBy: 1)
        XCTAssertTrue(waitUntilHittable(newest, timeout: 10), "The drawer must finish opening")
        // A row AppKit reports as disabled selects through accessibility without a mouse-down, so the
        // list never takes the keyboard. A coordinate click is a real mouse-down.
        clickAtCenter(newest)
        XCTAssertTrue(waitForPredicate(timeout: 5) { newest.isSelected }, "Clicking a row must select it")
        let preview = window.textViews.matching(identifier: "query-history-detail-query").firstMatch
        XCTAssertTrue(
            waitForEditorText(preview) { $0.contains("FROM artist") },
            "The preview must show the newest run, got '\(editorText(preview))'"
        )

        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(
            waitForEditorText(preview) { $0.contains("FROM album") },
            "Down arrow after a click must move to the next entry, got '\(editorText(preview))'"
        )
        XCTAssertEqual(editorText(editor), "", "Arrowing through history must not type into the editor")

        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(
            waitForEditorText(editor) { $0.contains("FROM album") },
            "Return must load the selected entry into the editor, got '\(editorText(editor))'"
        )
        XCTAssertEqual(editorTabs(in: window).count, tabCount, "Loading uses the tab in front instead of opening one")

        app.typeShortcut(.toggleHistory)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !list.exists || !list.isHittable },
            "Cmd+Y a second time must hide the drawer"
        )
    }

    // The drawer's preview is a text view too.
    private func queryEditor(in window: XCUIElement) -> XCUIElement {
        window.textViews.matching(NSPredicate(format: "identifier != %@", "query-history-detail-query")).firstMatch
    }
}
