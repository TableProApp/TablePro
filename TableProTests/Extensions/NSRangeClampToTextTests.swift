//
//  NSRangeClampToTextTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("NSRange clampedToTextLength")
struct NSRangeClampToTextTests {
    @Test("a range inside the text is untouched")
    func rangeInsideTextIsUnchanged() {
        #expect(NSRange(location: 2, length: 3).clampedToTextLength(10) == NSRange(location: 2, length: 3))
    }

    @Test("a range running past the end is trimmed to the end")
    func rangePastEndIsTrimmed() {
        #expect(NSRange(location: 8, length: 50).clampedToTextLength(10) == NSRange(location: 8, length: 2))
    }

    @Test("a location past the end collapses to a caret at the end")
    func locationPastEndCollapsesToEnd() {
        #expect(NSRange(location: 99, length: 4).clampedToTextLength(10) == NSRange(location: 10, length: 0))
    }

    @Test("a negative location is pulled back to the start")
    func negativeLocationClampsToStart() {
        #expect(NSRange(location: -5, length: 3).clampedToTextLength(10) == NSRange(location: 0, length: 0))
    }

    @Test("empty text collapses everything to zero")
    func emptyTextCollapsesToZero() {
        #expect(NSRange(location: 4, length: 9).clampedToTextLength(0) == NSRange(location: 0, length: 0))
    }
}
