import XCTest

final class EditorAutocompleteFocusUITests: UITestCase {
    func testTypingInNewTabKeepsEditorFocusWhileAutocompleteAppears() throws {
        let app = try launchWithSampleDatabase()

        app.typeKey("t", modifierFlags: .command)

        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitToExist(timeout: 10))
        XCTAssertTrue(waitForValue("", in: editor, timeout: 5), "New tab editor should start empty")

        app.typeText("select")

        XCTAssertTrue(
            waitForValue("select", in: editor, timeout: 5),
            "All typed characters must land in the editor; got '\(editor.value as? String ?? "nil")'"
        )
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
