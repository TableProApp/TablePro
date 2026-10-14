import XCTest

// Agent mode used to rebuild the browse content on every trip, and the query editor's undo stack lives
// in its text view, so a rebuilt editor showed the same text with nothing behind it to undo.
final class AgentModeRoundTripUITests: UITestCase {
    private let query = "SELECT 1"

    func testATripThroughAgentModeKeepsTheEditorsUndo() throws {
        let launch = try launchWithFixture()
        let app = launch.app
        let window = launch.window

        app.typeShortcut(.newTab)
        let editor = editorTextView(in: window)
        XCTAssertTrue(waitForEditorText(editor) { $0.isEmpty }, "Cmd+T must open an empty query tab")
        typeQuery(query, in: window)

        // A trip that never reached Agent mode would keep the editor trivially.
        app.typeShortcut(.toggleAgentMode)
        XCTAssertTrue(
            window.buttons["agent-session-add"].firstMatch.waitToExist(timeout: 15),
            "Cmd+Opt+Shift+A must put the window in Agent mode, whose sidebar lists sessions"
        )

        app.typeShortcut(.toggleAgentMode)
        XCTAssertTrue(waitUntilHittable(editor, timeout: 15), "Browsing must put the editor back")
        editor.click()
        XCTAssertEqual(editorText(editor), query, "The tab must still hold what was typed")

        app.typeShortcut(.undo)
        XCTAssertTrue(
            waitForEditorText(editor, timeout: 5) { $0 != self.query },
            "Undo must still reach the typing done before the trip; a rebuilt editor has nothing to undo"
        )
    }
}
