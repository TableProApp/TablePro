import XCTest

/// #2156: the trailing strip of the SQL editor, where a hidden minimap still sat, took clicks and
/// did nothing with them. Clicking there must move the caret to the clicked line like any other
/// empty space in the editor.
final class EditorTrailingClickUITests: UITestCase {
    private let query = "SELECT 1;"

    func testClickingTheTrailingEdgePutsTheCaretAtTheEndOfThatLine() throws {
        let app = try launchWithSampleDatabase()
        let editor = openQueryTab(in: app)

        app.typeText(query)
        XCTAssertTrue(waitForValue(query, in: editor))

        let frame = editor.frame
        XCTAssertGreaterThan(
            frame.width, 200,
            "The editor must be wide enough for the trailing strip to be distinct from the text"
        )

        // Click inside the text, which also dismisses any completion popup. Escape is not usable
        // here: with no popup open the editor treats it as a request to show completions.
        click(on: editor, dx: frame.width / 2, dy: 10)
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: .command)

        click(on: editor, dx: frame.width - 12, dy: 10)
        app.typeText("X")

        XCTAssertTrue(
            waitForValue(query + "X", in: editor),
            "A click on the editor's trailing edge must put the caret at the end of that line; got "
                + "'\(editor.value as? String ?? "nil")'"
        )
    }

    private func click(on element: XCUIElement, dx: CGFloat, dy: CGFloat) {
        element.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: dx, dy: dy))
            .click()
    }

    private func openQueryTab(in app: XCUIApplication) -> XCUIElement {
        app.typeKey("t", modifierFlags: .command)
        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitToExist(timeout: 10))
        XCTAssertTrue(waitForValue("", in: editor), "A new tab starts with an empty editor")
        return editor
    }

    private func waitForValue(_ expected: String, in element: XCUIElement) -> Bool {
        waitForPredicate(timeout: 5) { (element.value as? String) == expected }
    }
}
