import XCTest

// #2342: the first table opened after connecting stalled on "Executing…", and so did the first one
// opened in a window with no tabs left, which takes the add-first-tab path instead.
final class SQLiteFirstTableLoadUITests: UITestCase {
    func testTheFirstTableLoadsWithAndWithoutATab() throws {
        let launch = try launchWithFixture()
        let window = launch.window
        let grid = dataGrid(in: window)
        let editor = editorTextView(in: window)
        XCTAssertTrue(editor.waitToExist(timeout: 20), "The connection must restore its query tab")

        _ = openFromObjectBrowser("album", in: launch)
        XCTAssertTrue(
            waitForPredicate(timeout: 15) { !window.staticTexts["Executing…"].exists },
            "The first table opened after connecting must finish loading"
        )

        // The strip lists its tabs only while there are two or more.
        launch.app.typeShortcut(.closeTab)
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.editorTabCount(in: window) == 0 && editor.exists },
            "Command W must close the table tab and leave the query tab in front"
        )
        launch.app.typeShortcut(.closeTab)
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { !editor.exists && !grid.exists },
            "Command W must close the last tab"
        )
        XCTAssertTrue(
            objectBrowserRow("album", in: window).exists,
            "Closing the last tab must leave the connection open"
        )

        clickAtCenter(objectBrowserRow("album", in: window))
        XCTAssertTrue(
            waitForClickableRows(in: grid),
            "The first table opened in a window with no tabs must load its rows"
        )
    }
}
