import Foundation
@testable import TableProAutocomplete
import Testing

struct SQLCompletionWindowTests {
    @Test("A short text is analyzed whole")
    func shortTextIsWhole() {
        let window = SQLCompletionWindow.cut("SELECT * FROM or" as NSString, around: 16)
        #expect(window.text == "SELECT * FROM or")
        #expect(window.start == 0)
    }

    @Test("A long text is cut to the radius around the caret")
    func longTextIsCut() {
        let text = String(repeating: "x", count: 12_000) as NSString
        let window = SQLCompletionWindow.cut(text, around: 6_000)
        #expect(window.start == 1_000)
        #expect((window.text as NSString).length == 10_000)
    }

    @Test(
        "Nothing completes right after a statement break with nothing behind it",
        arguments: [
            ("SELECT 1;", 9, true),
            ("SELECT 1\n", 9, true),
            ("SELECT 1;\n  ", 9, true),
            ("SELECT 1; SELECT", 9, false),
            ("SELECT", 6, false),
            ("", 0, false)
        ]
    )
    func statementBreak(text: String, offset: Int, suppressed: Bool) {
        #expect(SQLCompletionTriggerPolicy.suppressesAfterStatementBreak(in: text as NSString, at: offset) == suppressed)
    }
}
