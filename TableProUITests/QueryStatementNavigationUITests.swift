import XCTest

/// The three commands driven the way a user reaches them, through the Query menu rather than the key equivalent,
/// because the shortcuts are rebindable and the menu item is the contract.
final class QueryStatementNavigationUITests: UITestCase {
    private let script = "SELECT 1;\nSELECT 2;\nSELECT 3;"

    func testTheQueryMenuOffersAllThreeStatementCommands() throws {
        let app = try launchWithSampleDatabase()
        let editor = openQueryTab(in: app)

        app.typeText(script)
        XCTAssertTrue(waitForEditorText(containing: "SELECT 3", in: editor))

        let queryMenu = app.menuBars.menuBarItems["Query"]
        XCTAssertTrue(queryMenu.waitToExist(timeout: 10))
        queryMenu.click()

        for title in ["Previous Statement", "Next Statement", "Run Statement and Advance"] {
            let item = app.menuBars.menuItems[title]
            XCTAssertTrue(item.waitToExist(timeout: 10), "Query > \(title) must exist")
            XCTAssertTrue(item.isEnabled, "Query > \(title) must be enabled on a query tab")
        }

        app.typeKey(.escape, modifierFlags: [])
    }

    func testNextStatementMovesTheCaretWithoutChangingTheDocument() throws {
        let app = try launchWithSampleDatabase()
        let editor = openQueryTab(in: app)

        app.typeText(script)
        XCTAssertTrue(waitForEditorText(containing: "SELECT 3", in: editor))

        clickQueryMenuItem("Previous Statement", in: app)
        clickQueryMenuItem("Previous Statement", in: app)

        XCTAssertTrue(
            waitForEditorText(containing: script, in: editor),
            "Moving the caret must never change the document text"
        )
    }

    /// The caret lands on the statement, so typing goes into it. That is the observable difference between a caret
    /// move and a no-op, and it is what the command exists for.
    func testTheCaretActuallyLandsOnTheTargetStatement() throws {
        let app = try launchWithSampleDatabase()
        let editor = openQueryTab(in: app)

        app.typeText(script)
        XCTAssertTrue(waitForEditorText(containing: "SELECT 3", in: editor))

        clickQueryMenuItem("Previous Statement", in: app)
        clickQueryMenuItem("Previous Statement", in: app)
        app.typeText("X")

        XCTAssertTrue(
            waitForEditorText(containing: "XSELECT 2;", in: editor),
            "the caret should have landed at the start of the second statement"
        )
    }

    // MARK: - Helpers

    /// Resolved and clicked in one step, with no click on the parent menu first. macOS exposes an
    /// unopened menu's items in the accessibility tree, so opening the parent buys nothing and
    /// costs XCUITest a second traversal of the menu bar, which measures at 4 to 6 seconds on the
    /// CI runner once a connection window is loaded. `launchWithSampleDatabase` has always relied
    /// on this.
    private func clickQueryMenuItem(_ title: String, in app: XCUIApplication) {
        let item = app.menuBars.menuItems[title]
        XCTAssertTrue(item.waitToExist(timeout: 10), "Query > \(title) must exist")
        item.click()
    }

    private func openQueryTab(in app: XCUIApplication) -> XCUIElement {
        app.typeKey("t", modifierFlags: .command)
        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitToExist(timeout: 10))
        return editor
    }

    private func waitForEditorText(
        containing needle: String,
        in editor: XCUIElement,
        timeout: TimeInterval = 10
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (editor.value as? String)?.contains(needle) == true {
                return true
            }
            usleep(200_000)
        }
        return false
    }
}
