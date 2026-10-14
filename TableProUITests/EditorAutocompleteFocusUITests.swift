import XCTest

final class EditorAutocompleteFocusUITests: UITestCase {
    // #2444: with the popup already open for `t`, typing the rest of `true` has to re-rank so the
    // preselected first row is the exact keyword, which is what Return then commits.
    func testAutocompleteKeepsFocusAndCommitsTheKeyword() throws {
        let launch = try launchWithFixture()
        let app = launch.app
        let window = launch.window

        app.typeShortcut(.newTab)
        let editor = editorTextView(in: window)
        XCTAssertTrue(editor.waitToExist(timeout: 10), "Cmd+T must open a query tab")
        XCTAssertTrue(waitForEditorText(editor) { $0.isEmpty }, "A new tab starts with an empty editor")

        app.typeText("sel")
        XCTAssertTrue(suggestion("select", in: app).waitToExist(timeout: 10), "Typing must raise the completion popup")
        app.typeText("ect")
        XCTAssertTrue(
            waitForEditorText(editor) { $0 == "select" },
            "Keys typed while the popup is up must land in the editor, got '\(editorText(editor))'"
        )

        app.typeText(" * from t where t")
        XCTAssertTrue(
            waitForEditorText(editor) { $0.lowercased() == "select * from t where t" },
            "The editor must hold the opening prefix, got '\(editorText(editor))'"
        )
        app.typeText("rue")
        XCTAssertTrue(suggestion("true", in: app).waitToExist(timeout: 10), "The popup must offer the typed keyword")
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            waitForEditorText(editor) { $0.lowercased() == "select * from t where true" },
            "Return must commit the keyword the typed token completes, got '\(editorText(editor))'"
        )
    }

    // The popup is a panel of its own, so it is looked for outside the connection window and the menu bar,
    // where the editor's own text would match too.
    private func suggestion(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.children(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier != %@ AND elementType != %lu",
                    "main",
                    XCUIElement.ElementType.menuBar.rawValue
                )
            )
            .descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label CONTAINS[c] %@ OR (elementType == %lu AND value CONTAINS[c] %@)",
                    text,
                    XCUIElement.ElementType.staticText.rawValue,
                    text
                )
            )
            .firstMatch
    }
}
