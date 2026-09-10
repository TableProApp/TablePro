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

    /// #2444: with the popup already open for `t`, typing the rest of `true` has to re-rank so the
    /// preselected first row is the exact keyword. The popup is a borderless panel whose rows are
    /// not reliably queryable, so this asserts the text Return actually inserts.
    func testTypingToAnExactKeywordCommitsThatKeyword() throws {
        let app = try launchWithSampleDatabase()

        app.typeKey("t", modifierFlags: .command)

        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitToExist(timeout: 10))
        XCTAssertTrue(waitForValue("", in: editor, timeout: 5), "New tab editor should start empty")

        app.typeText("select * from t where t")
        XCTAssertTrue(
            waitForValue(in: editor, timeout: 5) { $0.lowercased() == "select * from t where t" },
            "Editor should hold the opening prefix; got '\(editor.value as? String ?? "nil")'"
        )

        app.typeText("rue")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
        app.typeKey(.return, modifierFlags: [])

        let committed = waitForValue(in: editor, timeout: 5) {
            $0.lowercased().hasSuffix("true")
        }

        XCTAssertTrue(
            committed,
            "Return should commit the keyword the typed token completes; got "
                + "'\(editor.value as? String ?? "nil")'"
        )
    }

    private func waitForValue(
        in element: XCUIElement,
        timeout: TimeInterval,
        matching predicate: (String) -> Bool
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if predicate(element.value as? String ?? "") { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        return predicate(element.value as? String ?? "")
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
