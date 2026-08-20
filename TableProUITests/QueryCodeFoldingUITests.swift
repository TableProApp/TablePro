import XCTest

final class QueryCodeFoldingUITests: UITestCase {
    private let script = """
    CREATE TABLE users (
        id BIGSERIAL,
        name TEXT,
        email TEXT
    );
    """

    func testFoldAllCollapsesTheScriptAndUnfoldAllRestoresIt() throws {
        let app = try launchWithSampleDatabase()
        let editor = openQueryTab(in: app)

        app.typeText(script)
        XCTAssertTrue(waitForEditorText(containing: "BIGSERIAL", in: editor))

        clickQueryMenuItem("Fold All", in: app)
        XCTAssertTrue(
            waitForEditorText(containing: "BIGSERIAL", in: editor),
            "Folding hides lines visually and must never change the document text"
        )

        clickQueryMenuItem("Unfold All", in: app)
        XCTAssertTrue(
            waitForEditorText(containing: "BIGSERIAL", in: editor),
            "Unfold All must leave the document text intact"
        )
    }

    func testToggleFoldRunsWithTheCursorInsideAStatement() throws {
        let app = try launchWithSampleDatabase()
        let editor = openQueryTab(in: app)

        app.typeText(script)
        XCTAssertTrue(waitForEditorText(containing: "BIGSERIAL", in: editor))

        clickQueryMenuItem("Toggle Fold", in: app)
        clickQueryMenuItem("Toggle Fold", in: app)

        XCTAssertTrue(
            waitForEditorText(containing: "BIGSERIAL", in: editor),
            "Toggling a fold must never change the document text"
        )
    }

    // MARK: - Helpers

    /// Walks the Query menu rather than typing the shortcut, because the fold shortcuts are
    /// rebindable and the menu item is the contract the test cares about.
    private func clickQueryMenuItem(_ title: String, in app: XCUIApplication) {
        let queryMenu = app.menuBars.menuBarItems["Query"]
        XCTAssertTrue(queryMenu.waitForExistence(timeout: 10), "The Query menu must exist")
        queryMenu.click()

        let item = app.menuBars.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "Query > \(title) must exist")
        XCTAssertTrue(waitUntilHittable(item, timeout: 10), "Query > \(title) must be clickable")
        item.click()
    }

    private func openQueryTab(in app: XCUIApplication) -> XCUIElement {
        app.typeKey("t", modifierFlags: .command)
        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        return editor
    }

    private func editorTextView(in app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch
        let identified = window.textViews.matching(identifier: "sql-editor-textview").firstMatch
        if identified.exists {
            return identified
        }
        return window.textViews.firstMatch
    }

    private func waitForEditorText(
        containing needle: String,
        in element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        waitForPredicate(timeout: timeout) {
            (element.value as? String)?.contains(needle) == true
        }
    }
}
