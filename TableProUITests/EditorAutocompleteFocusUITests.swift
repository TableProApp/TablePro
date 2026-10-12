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

    /// #2833: the committed keyword takes the case of the typed prefix. Asserted on the exact
    /// string rather than a case-folded comparison, which is what the two tests above use and
    /// what would have let the old always-uppercase behaviour through.
    func testCommittedKeywordTakesTheTypedCase() throws {
        let app = try launchWithSampleDatabase()

        let editor = editorTextView(in: app)
        for (typed, expected) in [("sel", "select"), ("SEL", "SELECT")] {
            app.typeKey("t", modifierFlags: .command)
            XCTAssertTrue(editor.waitToExist(timeout: 10))
            XCTAssertTrue(waitForValue("", in: editor, timeout: 5), "New tab editor should start empty")

            app.typeText(typed)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
            app.typeKey(.return, modifierFlags: [])

            XCTAssertTrue(
                waitForValue(expected, in: editor, timeout: 5),
                "Typing '\(typed)' and accepting should commit '\(expected)'; got "
                    + "'\(editor.value as? String ?? "nil")'"
            )
        }
    }

    /// #2915: a request that came back with nothing used to leave the model claiming the editor,
    /// and every later prefix the stale candidates could still rank updated a panel that was no
    /// longer on screen. Measured before the fix: after `zqxj`, typing `sel` on an emptied editor
    /// made no request and showed no popup, so Return committed nothing.
    func testPopupReturnsAfterARequestWithNoMatches() throws {
        let app = try launchWithSampleDatabase()

        app.typeKey("t", modifierFlags: .command)

        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitToExist(timeout: 10))
        XCTAssertTrue(waitForValue("", in: editor, timeout: 5), "New tab editor should start empty")

        app.typeText("zqxj")
        XCTAssertTrue(
            waitForValue("zqxj", in: editor, timeout: 5),
            "Editor should hold the no-match prefix; got '\(editor.value as? String ?? "nil")'"
        )
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))

        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitForValue("", in: editor, timeout: 5), "Editor should be empty again")

        app.typeText("sel")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            waitForValue("select", in: editor, timeout: 5),
            "A no-match prefix must not leave the popup dead; got "
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
