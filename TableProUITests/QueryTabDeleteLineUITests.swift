import XCTest

final class QueryTabDeleteLineUITests: XCTestCase {
    private let query = "SELECT * FROM Genre;"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
    }

    func testCommandDeleteDeletesTheEditorLineAfterRunningAQuery() throws {
        let app = launchWithSampleDatabase()
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
        let app = launchWithSampleDatabase()
        let editor = openQueryTab(in: app)

        app.typeText(query)
        XCTAssertTrue(waitForValue(query, in: editor, timeout: 5))
        executeQuery(in: app)

        let firstRow = app.windows.firstMatch.tables.firstMatch.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
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

    private func launchWithSampleDatabase() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TABLEPRO_UI_TESTING"] = "1"
        app.launch()

        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitForExistence(timeout: 10))
        menuBar.menuBarItems["File"].click()
        let openSample = menuBar.menuItems["Open Sample Database"]
        XCTAssertTrue(openSample.waitForExistence(timeout: 5))
        openSample.click()

        XCTAssertTrue(editorTextView(in: app).waitForExistence(timeout: 15))
        return app
    }

    private func openQueryTab(in app: XCUIApplication) -> XCUIElement {
        app.typeKey("t", modifierFlags: .command)
        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForValue("", in: editor, timeout: 5), "A new tab starts with an empty editor")
        return editor
    }

    private func executeQuery(in app: XCUIApplication) {
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: .command)
        let results = app.windows.firstMatch.tables.firstMatch
        XCTAssertTrue(results.waitForExistence(timeout: 15), "The query must produce a result grid")
    }

    private func editorTextView(in app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch
        let identified = window.textViews.matching(identifier: "sql-editor-textview").firstMatch
        if identified.exists {
            return identified
        }
        return window.textViews.firstMatch
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
