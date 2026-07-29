//
//  SqlWalkthroughAnchorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SqlWalkthroughAnchor")
struct SqlWalkthroughAnchorTests {
    @Test("An in-range before anchor is valid")
    func validBefore() {
        let anchor = SqlWalkthroughAnchor(side: .before, startLine: 1, endLine: 3)
        #expect(anchor.isValid(beforeLineCount: 5, afterLineCount: 0))
    }

    @Test("A zero start line is invalid")
    func invalidZeroStart() {
        let anchor = SqlWalkthroughAnchor(side: .before, startLine: 0, endLine: 2)
        #expect(!anchor.isValid(beforeLineCount: 5, afterLineCount: 5))
    }

    @Test("An end line beyond the line count is invalid")
    func invalidEndBeyondCount() {
        let anchor = SqlWalkthroughAnchor(side: .after, startLine: 1, endLine: 10)
        #expect(!anchor.isValid(beforeLineCount: 5, afterLineCount: 5))
    }

    @Test("An end line before the start line is invalid")
    func invalidReversedRange() {
        let anchor = SqlWalkthroughAnchor(side: .after, startLine: 3, endLine: 2)
        #expect(!anchor.isValid(beforeLineCount: 5, afterLineCount: 5))
    }

    @Test("A both-sided anchor requires both sides in range")
    func bothRequiresBothSides() {
        let anchor = SqlWalkthroughAnchor(side: .both, startLine: 1, endLine: 4)
        #expect(anchor.isValid(beforeLineCount: 4, afterLineCount: 6))
        #expect(!anchor.isValid(beforeLineCount: 3, afterLineCount: 6))
    }

    @Test("An after anchor ignores the before line count")
    func afterIgnoresBeforeCount() {
        let anchor = SqlWalkthroughAnchor(side: .after, startLine: 1, endLine: 2)
        #expect(anchor.isValid(beforeLineCount: 0, afterLineCount: 2))
    }
}
