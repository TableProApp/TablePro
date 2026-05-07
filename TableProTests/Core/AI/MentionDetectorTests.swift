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
}
