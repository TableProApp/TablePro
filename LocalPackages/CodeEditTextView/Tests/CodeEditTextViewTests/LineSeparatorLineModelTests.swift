import AppKit
@testable import CodeEditTextView
import Testing

@Suite("Lines break at LF, CR and CRLF only")
@MainActor
struct LineSeparatorLineModelTests {
    @Test(
        "Unicode line and paragraph separators and NEL do not start a new line",
        arguments: ["\u{2028}", "\u{2029}", "\u{85}"]
    )
    func separatorsStayInTheLine(separator: String) {
        let textView = TextView(string: "SELECT 1\(separator)FROM t")
        #expect(textView.layoutManager.lineCount == 1)
    }

    @Test("LF, CR and CRLF each end a line")
    func lineEndingsBreak() {
        #expect(TextView(string: "a\nb").layoutManager.lineCount == 2)
        #expect(TextView(string: "a\rb").layoutManager.lineCount == 2)
        #expect(TextView(string: "a\r\nb").layoutManager.lineCount == 2)
    }

    @Test("The next line ending skips separators and treats CRLF as one terminator")
    func nextLineEnding() {
        let text = "a\u{2028}b\r\nc" as NSString
        #expect(text.getNextLine(startingAt: 0) == NSRange(location: 3, length: 2))
        #expect(text.getNextLine(startingAt: 4) == NSRange(location: 3, length: 2))
        #expect(text.getNextLine(startingAt: 5) == nil)
    }

    @Test("A whole-line range agrees with the line model")
    func wholeLineRange() {
        let text = "one\u{2028}two\r\nthree\nfour" as NSString
        let lineRange = { (location: Int, length: Int) in
            text.lineRangeBreakingAtLineEndings(for: NSRange(location: location, length: length))
        }
        #expect(lineRange(5, 0) == NSRange(location: 0, length: 9))
        #expect(lineRange(8, 0) == NSRange(location: 0, length: 9))
        #expect(lineRange(9, 2) == NSRange(location: 9, length: 6))
        #expect(lineRange(16, 0) == NSRange(location: 15, length: 4))
    }

    @Test("Inserting a separator in the middle of a line keeps one line")
    func insertingSeparatorKeepsOneLine() {
        let textView = TextView(string: "SELECT 1 FROM t")
        textView.replaceCharacters(in: NSRange(location: 8, length: 1), with: "\u{2028}")
        #expect(textView.layoutManager.lineCount == 1)
    }
}
