import XCTest

/// #2172. Command+C in the query editor with nothing selected used to clear the pasteboard and
/// write an empty string, so the next Command+V pasted nothing and the user's clipboard was gone.
/// The test never writes the pasteboard itself; every copy and paste happens inside the app, so
/// nothing here depends on the runner handing content across the process boundary.
final class EditorClipboardUITests: UITestCase {
    private let query = "SELECT * FROM Genre;"

    func testCopyWithNoSelectionKeepsSomethingOnTheClipboard() throws {
        let app = try launchWithSampleDatabase()
        let editor = openQueryTab(in: app)

        app.typeText(query)
        XCTAssertTrue(waitForValue(query, in: editor, timeout: 5))

        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)

        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)

        app.typeKey("a", modifierFlags: .command)
        app.typeKey("v", modifierFlags: .command)

        XCTAssertTrue(
            waitForPredicate(timeout: 5) { (editor.value as? String)?.contains("Genre") == true },
            "Command+C with no selection must not empty the clipboard; editor holds "
                + "'\(editor.value as? String ?? "nil")'"
        )
    }

    func testPasteReplacesTheSelectionInTheEditor() throws {
        let app = try launchWithSampleDatabase()
        let editor = openQueryTab(in: app)

        app.typeText(query)
        XCTAssertTrue(waitForValue(query, in: editor, timeout: 5))

        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("v", modifierFlags: .command)

        XCTAssertTrue(
            waitForValue(query, in: editor, timeout: 5),
            "Command+V must replace the selection with the copied query; editor holds "
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

    private func waitForValue(_ expected: String, in element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitForPredicate(timeout: timeout) { (element.value as? String) == expected }
    }
}
