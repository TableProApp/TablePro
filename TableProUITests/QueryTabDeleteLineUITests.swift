import XCTest

final class QueryTabDeleteLineUITests: UITestCase {
    private let query = "SELECT * FROM Genre;"

    func testCommandDeleteDeletesTheEditorLineAfterRunningAQuery() throws {
        let app = try launchWithSampleDatabase()
        let editor = openQueryTab(in: app)

        app.typeText(query)
        XCTAssertTrue(waitForValue(query, in: editor, timeout: 5))
        executeQuery(in: app)

        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: .command)

        XCTAssertTrue(
            waitForValue("", in: editor, timeout: 5),
            "Cmd+Delete must delete to the start of the line; got '\(editor.value as? String ?? "nil")'"
        )
    }

    func testCommandDeleteDeletesTheEditorLineAfterSelectingAResultRow() throws {
        let app = try launchWithSampleDatabase()
        let editor = openQueryTab(in: app)

        app.typeText(query)
        XCTAssertTrue(waitForValue(query, in: editor, timeout: 5))
        executeQuery(in: app)

        let grid = app.windows.firstMatch.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 10))
        let firstRow = grid.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitToExist(timeout: 10))
        firstRow.click()

        editor.click()
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: .command)
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: .command)

        XCTAssertTrue(
            waitForValue("", in: editor, timeout: 5),
            "A selected result row must not steal Cmd+Delete from the editor; got "
                + "'\(editor.value as? String ?? "nil")'"
        )
    }

    private func openQueryTab(in app: XCUIApplication) -> XCUIElement {
        app.typeKey("t", modifierFlags: .command)
        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitToExist(timeout: 10))
        XCTAssertTrue(waitForValue("", in: editor, timeout: 5), "A new tab starts with an empty editor")
        return editor
    }

    private func executeQuery(in app: XCUIApplication) {
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: .command)
        let results = app.windows.firstMatch.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(results.waitToExist(timeout: 15), "The query must produce a result grid")
    }

    private func waitForValue(_ expected: String, in element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if (element.value as? String) == expected {
                return true
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        return (element.value as? String) == expected
    }
}
