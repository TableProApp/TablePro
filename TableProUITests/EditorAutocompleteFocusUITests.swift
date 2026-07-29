import XCTest

final class EditorAutocompleteFocusUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIApplication().terminate()
    }

    func testTypingInNewTabKeepsEditorFocusWhileAutocompleteAppears() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TABLEPRO_UI_TESTING"] = "1"
        app.launch()

        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitForExistence(timeout: 10))
        menuBar.menuBarItems["File"].click()
        let openSample = menuBar.menuItems["Open Sample Database"]
        XCTAssertTrue(openSample.waitForExistence(timeout: 5))
        openSample.click()

        let firstEditor = editorTextView(in: app)
        XCTAssertTrue(firstEditor.waitForExistence(timeout: 15))

        app.typeKey("t", modifierFlags: .command)

        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForValue("", in: editor, timeout: 5), "New tab editor should start empty")

        app.typeText("select")

        XCTAssertTrue(
            waitForValue("select", in: editor, timeout: 5),
            "All typed characters must land in the editor; got '\(editor.value as? String ?? "nil")'"
        )
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
