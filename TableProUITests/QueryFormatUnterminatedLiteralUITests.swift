import XCTest

final class QueryFormatUnterminatedLiteralUITests: UITestCase {
    // A backtick, not a quote. `BracketPairs.allValues` auto-closes `'` and `"`, so a typed quote
    // gets a closing partner and the document no longer ends in the backslash that trips the
    // tokenizer. Backticks are not paired, and they take the same tokenizer branch.
    private let query = "select * from t where c like `C:\\"

    func testFormatQuerySurvivesAnUnterminatedLiteralEndingInABackslash() throws {
        let app = try launchWithSampleDatabase()
        let editor = openQueryTab(in: app)

        app.typeText(query)
        XCTAssertTrue(waitForValue(query, in: editor, timeout: 5))

        app.typeKey("l", modifierFlags: [.command, .shift])

        XCTAssertTrue(
            app.windows.firstMatch.waitToExist(timeout: 5),
            "Formatting an unterminated literal must not bring the app down"
        )
        XCTAssertTrue(
            editor.waitToExist(timeout: 5),
            "The editor must survive formatting an unterminated literal"
        )
        let value = editor.value as? String ?? ""
        // The typed keywords are lowercase and the formatter uppercases them, so this also proves
        // the command ran rather than silently doing nothing.
        XCTAssertTrue(
            value.contains("SELECT"),
            "Format Query must actually reformat the editor; got '\(value)'"
        )
        XCTAssertTrue(
            value.contains("`C:\\"),
            "Formatting must keep the unterminated literal; got '\(value)'"
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
