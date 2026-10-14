import XCTest

final class QueryRunUITests: UITestCase {
    private let query = "SELECT title FROM album;"

    // No table stands behind these results, so each one has to be named after its statement.
    private let script = """
    -- monthly totals
    SELECT 1;
    SELECT 2;
    """

    func testRunningAStatementAndAScript() throws {
        let launch = try launchWithFixture()
        let app = launch.app
        let window = launch.window

        app.typeShortcut(.newTab)
        let editor = editorTextView(in: window)
        XCTAssertTrue(editor.waitToExist(timeout: 10), "Cmd+T must open a query tab")
        XCTAssertTrue(waitForEditorText(editor) { $0.isEmpty }, "A new tab starts with an empty editor")

        typeQuery(query, in: window)
        app.typeShortcut(.runQuery)
        let grid = dataGrid(in: window)
        XCTAssertTrue(waitForClickableRows(in: grid), "Cmd+Return must run the statement into a grid")
        XCTAssertTrue(gridCell(showing: "North", in: grid).waitToExist(timeout: 10), "The grid must hold album's titles")

        app.typeKey(.delete, modifierFlags: .command)
        XCTAssertTrue(
            waitForEditorText(editor) { $0.isEmpty },
            "After a run, Cmd+Delete must delete the editor line; editor holds '\(editorText(editor))'"
        )

        typeQuery(query, in: window)
        let firstRow = grid.tableRows.element(boundBy: 0)
        gridPoint(in: grid, of: window, dy: firstRow.frame.midY - grid.frame.minY).click()
        XCTAssertTrue(waitForPredicate(timeout: 10) { firstRow.isSelected }, "Clicking a result row must select it")
        editor.click()
        app.typeKey(.rightArrow, modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: .command)
        XCTAssertTrue(
            waitForEditorText(editor) { $0.isEmpty },
            "A selected result row must not take Cmd+Delete from the editor; editor holds '\(editorText(editor))'"
        )

        typeQuery(script, in: window)
        app.typeShortcut(.runAllStatements)
        let chooser = resultSetChooser(in: window)
        XCTAssertTrue(chooser.waitToExist(timeout: 20), "Cmd+Shift+Return must report a result per statement")
        // A SwiftUI Menu publishes its label content as AXTitle; `label` stays empty.
        XCTAssertTrue(
            waitForPredicate(timeout: 15) { chooser.title.contains("of 2") || chooser.title.hasSuffix("/2") },
            "Both statements must run, got \(chooser.title)"
        )

        XCTAssertTrue(waitUntilHittable(chooser, timeout: 10))
        chooser.click()
        // A just-opened pull-down has no identifier on the runner's macOS build, so it is scoped to the window.
        let items = window.menus.firstMatch.menuItems
        XCTAssertTrue(items.firstMatch.waitToExist(timeout: 5), "The chooser must list its results")
        let names = items.allElementsBoundByIndex.map { $0.title }
        XCTAssertTrue(
            names.contains { $0.contains("monthly totals") },
            "A statement with a leading comment is named after it, got \(names)"
        )
        XCTAssertTrue(names.contains { $0.hasPrefix("SELECT 2") }, "A bare statement is named after its text, got \(names)")
        XCTAssertFalse(names.contains { $0.hasPrefix("Result ") }, "No result may fall back to its position, got \(names)")
        app.typeKey(.escape, modifierFlags: [])
    }
}
