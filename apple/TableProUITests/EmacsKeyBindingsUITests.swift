import XCTest

final class EmacsKeyBindingsUITests: UITestCase {
    // Ctrl+@ sets the mark here: macOS can take Ctrl+Space for switching input sources before the app sees it.
    func testEmacsKeysMoveKillAndYank() throws {
        let launch = try launchWithFixture()
        let app = launch.app
        chooseKeyBindings("Emacs", in: app)

        app.typeShortcut(.newTab)
        let editor = editorTextView(in: launch.window)
        XCTAssertTrue(editor.waitToExist(timeout: 10), "Cmd+T must open a query tab")
        XCTAssertTrue(waitForEditorText(editor) { $0.isEmpty }, "A new tab starts with an empty editor")

        typeQuery("SELECT id FROM users", in: launch.window)

        app.typeKey("a", modifierFlags: .control)
        app.typeKey("f", modifierFlags: .option)
        app.typeKey("f", modifierFlags: .control)
        app.typeKey("2", modifierFlags: [.control, .shift])
        app.typeKey("f", modifierFlags: .option)
        app.typeKey("w", modifierFlags: .control)
        expectText("SELECT  FROM users", in: editor, "Ctrl+@, Option+F and Ctrl+W must kill the word after the mark")

        app.typeKey("e", modifierFlags: .control)
        app.typeKey("y", modifierFlags: .control)
        app.typeKey("t", modifierFlags: .control)
        expectText("SELECT  FROM usersdi", in: editor, "Ctrl+Y must yank the kill at the line end, and Ctrl+T swap the last two")

        app.typeKey("a", modifierFlags: .control)
        app.typeKey("d", modifierFlags: .option)
        app.typeKey("d", modifierFlags: .option)
        expectText(" usersdi", in: editor, "Option+D twice must kill two words")

        // #2539: the Backspace in between used to replace the kill in the ring.
        app.typeKey("e", modifierFlags: .control)
        app.typeKey(.delete, modifierFlags: [])
        app.typeKey("y", modifierFlags: .control)
        expectText(" usersdSELECT  FROM", in: editor, "Ctrl+Y after Backspace must yank both killed words as one entry")
    }

    private func expectText(_ expected: String, in editor: XCUIElement, _ message: String) {
        XCTAssertTrue(waitForEditorText(editor) { $0 == expected }, "\(message); editor holds '\(editorText(editor))'")
    }
}
