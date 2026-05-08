//
//  MentionDetectorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("MentionDetector")
struct MentionDetectorTests {
    @Test("Empty text returns nil")
    func emptyText() {
        #expect(MentionDetector.detect(in: "", caret: 0) == nil)
    }

    @Test("Out-of-range caret returns nil")
    func outOfRangeCaret() {
        #expect(MentionDetector.detect(in: "hello", caret: -1) == nil)
        #expect(MentionDetector.detect(in: "hello", caret: 99) == nil)
    }

    @Test("@ at start with empty query")
    func atStartEmptyQuery() {
        let match = MentionDetector.detect(in: "@", caret: 1)
        #expect(match?.range == NSRange(location: 0, length: 1))
        #expect(match?.query == "")
    }

    @Test("@ at start with partial query")
    func atStartWithQuery() {
        let match = MentionDetector.detect(in: "@user", caret: 5)
        #expect(match?.range == NSRange(location: 0, length: 5))
        #expect(match?.query == "user")
    }

    @Test("@ after whitespace boundary")
    func afterWhitespace() {
        let match = MentionDetector.detect(in: "explain @us", caret: 11)
        #expect(match?.range == NSRange(location: 8, length: 3))
        #expect(match?.query == "us")
    }

    @Test("@ inside email-like word does not match")
    func notInsideWord() {
        #expect(MentionDetector.detect(in: "user@host", caret: 9) == nil)
    }

    @Test("Caret past whitespace after token cancels match")
    func caretPastWhitespace() {
        #expect(MentionDetector.detect(in: "@users now", caret: 10) == nil)
    }

    @Test("@ after punctuation is a valid boundary")
    func afterPunctuation() {
        let match = MentionDetector.detect(in: "(@us", caret: 4)
        #expect(match?.range == NSRange(location: 1, length: 3))
        #expect(match?.query == "us")
    }

    @Test("Underscore and digits are query characters")
    func underscoresAndDigits() {
        let match = MentionDetector.detect(in: "@user_42", caret: 8)
        #expect(match?.query == "user_42")
    }

    @Test("Caret inside the partial query truncates query at caret")
    func caretInsidePartialQuery() {
        let match = MentionDetector.detect(in: "@users", caret: 3)
        #expect(match?.range == NSRange(location: 0, length: 3))
        #expect(match?.query == "us")
    }

    @Test("Newline before @ is a boundary")
    func newlineBoundary() {
        let match = MentionDetector.detect(in: "first line\n@ta", caret: 14)
        #expect(match?.query == "ta")
    }

    @Test("Non-ASCII letter is treated as a query character")
    func nonAsciiLetterInQuery() {
        let match = MentionDetector.detect(in: "@niño", caret: 5)
        #expect(match?.query == "niño")
    }

    @Test("Emoji directly before @ is treated as a boundary, no surrogate confusion")
    func emojiBoundaryBeforeTrigger() {
        let text = "hi 😀@tab"
        let caret = (text as NSString).length
        let match = MentionDetector.detect(in: text, caret: caret)
        let triggerLocation = (text as NSString).range(of: "@").location
        #expect(match?.query == "tab")
        #expect(match?.range == NSRange(location: triggerLocation, length: caret - triggerLocation))
    }

    @Test("Emoji inside the query token does not break detection")
    func emojiInsideQueryStops() {
        let text = "@🚀"
        let caret = (text as NSString).length
        #expect(MentionDetector.detect(in: text, caret: caret) == nil)
    }

    @Test("Caret right after a non-BMP scalar with no @ returns nil")
    func nonBmpAfterCaretWithoutTrigger() {
        let text = "hello 😀"
        let caret = (text as NSString).length
        #expect(MentionDetector.detect(in: text, caret: caret) == nil)
    }
}
