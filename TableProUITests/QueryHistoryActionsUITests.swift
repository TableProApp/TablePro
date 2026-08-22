import XCTest

/// Sending a query from the drawer back to the editor is the reason the drawer exists, and every
/// way of asking for it shipped dead: the buttons, the context menu and the list's own Return all
/// funnelled into one handler that resolved its target through a channel this app cannot serve.
/// Nothing here asserted that a click changed anything, which is why it reached a release.
final class QueryHistoryActionsUITests: UITestCase {
    private let marker = "tablepro_probe"
    private var probeQuery: String { "SELECT '\(marker)' AS marker;" }

    func testLoadInEditorFillsTheTabInFrontInsteadOfOpeningAnother() throws {
        let app = try launchWithSampleDatabase()
        runProbeQuery(in: app)
        openEmptyTab(in: app)

        showHistoryDrawer(in: app)
        selectFirstEntry(in: app)
        XCTAssertEqual(editorsShowingMarker(in: app), 1, "Only the drawer's preview shows the query yet")
        let tabsBefore = tabCount(in: app)

        let load = app.buttons["query-history-load-in-editor"]
        XCTAssertTrue(load.waitToExist(timeout: 10), "The detail pane must offer Load in Editor")
        load.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 10) { editorsShowingMarker(in: app) == 2 },
            "Load in Editor must put the selected query into the editor"
        )
        XCTAssertEqual(
            tabCount(in: app),
            tabsBefore,
            "Load in Editor uses the tab in front rather than opening another one"
        )
    }

    /// The list owns Return, so the keyboard reaches the same handler the buttons do.
    func testReturnInTheListLoadsTheSelectedEntry() throws {
        let app = try launchWithSampleDatabase()
        runProbeQuery(in: app)
        openEmptyTab(in: app)

        showHistoryDrawer(in: app)
        selectFirstEntry(in: app)

        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])

        XCTAssertTrue(
            waitForPredicate(timeout: 10) { editorsShowingMarker(in: app) == 2 },
            "Return on a selected entry must load it into the editor"
        )
    }

    func testRunInNewTabOpensATabAndActuallyRunsTheQuery() throws {
        let app = try launchWithSampleDatabase()
        runProbeQuery(in: app)
        openEmptyTab(in: app)

        showHistoryDrawer(in: app)
        selectFirstEntry(in: app)
        let tabsBefore = tabCount(in: app)

        let run = app.buttons["query-history-run-in-new-tab"]
        XCTAssertTrue(run.waitToExist(timeout: 10), "The detail pane must offer Run in New Tab")
        run.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 15) { tabCount(in: app) > tabsBefore },
            "Run in New Tab must open another editor tab"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 15) {
                app.windows.firstMatch.descendants(matching: .any)
                    .matching(NSPredicate(format: "value == %@", marker)).firstMatch.exists
            },
            "Run in New Tab must run the query it opens, not just load it"
        )
    }

    // MARK: - Helpers

    private func tabCount(in app: XCUIApplication) -> Int {
        app.buttons.matching(identifier: "editor-tab").count
    }

    /// The drawer's preview is a text view too, so the marker's own count is what separates
    /// "the editor received it" from "the drawer is merely showing it".
    private func editorsShowingMarker(in app: XCUIApplication) -> Int {
        app.windows.firstMatch.textViews
            .matching(NSPredicate(format: "value CONTAINS %@", marker)).count
    }

    private func showHistoryDrawer(in app: XCUIApplication) {
        app.typeKey("y", modifierFlags: .command)
        let detail = app.windows.firstMatch.descendants(matching: .any)
            .matching(identifier: "query-history-detail").firstMatch
        XCTAssertTrue(detail.waitToExist(timeout: 10), "Cmd+Y must show the query history drawer")
    }

    /// Row 0 is the day section header, so the first entry is row 1.
    private func selectFirstEntry(in app: XCUIApplication) {
        let list = app.windows.firstMatch.tables.matching(identifier: "query-history-list").firstMatch
        XCTAssertTrue(list.waitToExist(timeout: 10))
        let row = list.tableRows.element(boundBy: 1)
        XCTAssertTrue(row.waitToExist(timeout: 10), "The drawer must list the query just run")
        row.click()

        let preview = app.textViews["query-history-detail-query"]
        XCTAssertTrue(preview.waitToExist(timeout: 10))
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { ((preview.value as? String) ?? "").contains(marker) },
            "Selecting a row must show that row in the preview"
        )
    }

    private func openEmptyTab(in app: XCUIApplication) {
        app.typeKey("t", modifierFlags: .command)
        let editor = app.windows.firstMatch.textViews.firstMatch
        XCTAssertTrue(editor.waitToExist(timeout: 10))
        XCTAssertTrue(
            waitForPredicate(timeout: 5) { editorsShowingMarker(in: app) == 0 },
            "A tab opened with Cmd+T starts empty"
        )
    }

    private func runProbeQuery(in app: XCUIApplication) {
        app.typeKey("t", modifierFlags: .command)
        let editor = app.windows.firstMatch.textViews.firstMatch
        XCTAssertTrue(editor.waitToExist(timeout: 10))
        app.typeText(probeQuery)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: .command)

        let results = app.windows.firstMatch.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(results.waitToExist(timeout: 15), "The query must produce a result grid")
    }
}
