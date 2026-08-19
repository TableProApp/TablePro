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
        XCTAssertTrue(waitForValueContaining("BIGSERIAL", in: editor, timeout: 5))

        clickQueryMenuItem("Fold All", in: app)

        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 5),
            "Folding must not bring the app down"
        )
        XCTAssertTrue(
            editor.waitForExistence(timeout: 5),
            "The editor must survive Fold All"
        )
        XCTAssertTrue(
            waitForValueContaining("BIGSERIAL", in: editor, timeout: 5),
            "Folding hides lines visually and must never change the document text"
        )

        clickQueryMenuItem("Unfold All", in: app)

        XCTAssertTrue(
            waitForValueContaining("BIGSERIAL", in: editor, timeout: 5),
            "Unfold All must leave the document text intact"
        )
    }

    func testToggleFoldRunsWithTheCursorInsideAStatement() throws {
        let app = try launchWithSampleDatabase()
        let editor = openQueryTab(in: app)

        app.typeText(script)
        XCTAssertTrue(waitForValueContaining("BIGSERIAL", in: editor, timeout: 5))

        clickQueryMenuItem("Toggle Fold", in: app)
        clickQueryMenuItem("Toggle Fold", in: app)

        XCTAssertTrue(
            editor.waitForExistence(timeout: 5),
            "Toggling a fold twice must leave a working editor"
        )
        XCTAssertTrue(
            waitForValueContaining("BIGSERIAL", in: editor, timeout: 5),
            "Toggling a fold must never change the document text"
        )
    }

    func testTheThreeFoldCommandsAreInTheQueryMenu() throws {
        let app = try launchWithSampleDatabase()

        let queryMenu = app.menuBars.menuBarItems["Query"]
        XCTAssertTrue(queryMenu.waitForExistence(timeout: 10), "The Query menu must exist")
        queryMenu.click()

        for title in ["Toggle Fold", "Fold All", "Unfold All"] {
            XCTAssertTrue(
                app.menuBars.menuItems[title].waitForExistence(timeout: 10),
                "Query > \(title) must exist"
            )
        }

        app.typeKey(.escape, modifierFlags: [])
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

    private func waitForValueContaining(
        _ needle: String,
        in element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if (element.value as? String)?.contains(needle) == true {
                return true
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        return (element.value as? String)?.contains(needle) == true
    }
}
