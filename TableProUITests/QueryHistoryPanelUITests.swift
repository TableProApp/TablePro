import XCTest

final class QueryHistoryPanelUITests: UITestCase {
    private let query = "SELECT * FROM Genre;"

    /// One launch for the whole drawer.
    ///
    /// Each of these was a separate test that launched the app, opened the sample database, ran a
    /// query and pressed Cmd+Y to reach the drawer the previous one had just been looking at. They
    /// all observe one drawer, so the preamble was the only thing they were not sharing.
    ///
    /// Toggling the drawer shut comes last, because it is the one step that leaves the window in a
    /// state the other assertions could not run in.
    ///
    /// `continueAfterFailure` is on because the phases are independent: with it off, a drawer that
    /// lost its search field would hide whether the scope picker and the detail pane are still
    /// there, and one CI run would report one of the five problems it could have reported.
    func testTheHistoryDrawerListsTheQueryCarriesItsFiltersAndTogglesShut() throws {
        continueAfterFailure = true
        let app = try launchWithSampleDatabase()
        runQuery(in: app)
        let list = showHistoryDrawer(in: app)

        XCTAssertTrue(
            waitForPredicate(timeout: 10) {
                list.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "Genre", "Genre"))
                    .firstMatch.exists
            },
            "The query that just ran must appear in the drawer"
        )

        let window = app.windows.firstMatch
        let historySearch = window.searchFields.matching(identifier: "query-history-search-field").firstMatch
        XCTAssertTrue(historySearch.waitToExist(timeout: 10), "The drawer must own a search field")

        let sidebarFilter = window.searchFields.matching(identifier: "sidebar-filter").firstMatch
        XCTAssertTrue(sidebarFilter.exists, "The sidebar filter must keep its own identifier")

        let scope = window.popUpButtons.matching(identifier: "query-history-scope-picker").firstMatch
        let date = window.popUpButtons.matching(identifier: "query-history-date-picker").firstMatch
        XCTAssertTrue(scope.waitToExist(timeout: 10), "The drawer must expose the connection scope")
        XCTAssertTrue(date.exists, "The drawer must expose the date range")
        XCTAssertEqual(scope.value as? String, "This Connection", "History starts scoped to this connection")

        let detail = window.descendants(matching: .any)
            .matching(identifier: "query-history-detail").firstMatch
        XCTAssertTrue(detail.waitToExist(timeout: 10), "The drawer is master-detail")

        app.typeKey("y", modifierFlags: .command)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !list.exists || !list.isHittable },
            "Cmd+Y a second time must hide the drawer"
        )
    }

    // MARK: - Helpers

    @discardableResult
    private func showHistoryDrawer(in app: XCUIApplication) -> XCUIElement {
        app.typeKey("y", modifierFlags: .command)
        let list = app.windows.firstMatch.descendants(matching: .any)
            .matching(identifier: "query-history-list").firstMatch
        XCTAssertTrue(list.waitToExist(timeout: 10), "Cmd+Y must show the query history drawer")
        return list
    }

    private func runQuery(in app: XCUIApplication) {
        app.typeKey("t", modifierFlags: .command)
        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitToExist(timeout: 10))
        app.typeText(query)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: .command)

        let results = app.windows.firstMatch.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(results.waitToExist(timeout: 15), "The query must produce a result grid")
    }
}
