//
//  SQLTokenBoundaryTests.swift
//  TableProTests
//
//  Tests for SQLTokenBoundary: the shared identifier-boundary rule used by
//  the context analyzer and the completion adapter. Includes the regression
//  for accepting a completion with a stale stored range (typing "mess" then
//  Tab must produce "message", never "memessage").
//

import Foundation
@testable import TablePro
import Testing

@Suite("SQLTokenBoundary")
struct SQLTokenBoundaryTests {
    @Test("Segment start covers the whole typed word")
    func segmentStartPlainWord() {
        let text = "SELECT mess" as NSString
        #expect(SQLTokenBoundary.segmentStart(in: text, endingAt: 11) == 7)
    }

    @Test("Segment start stops at a dot so only the last segment is replaced")
    func segmentStartAfterDot() {
        let text = "SELECT users.na" as NSString
        #expect(SQLTokenBoundary.segmentStart(in: text, endingAt: 15) == 13)
    }

    @Test("Segment start includes an opening identifier quote")
    func segmentStartQuotedIdentifier() {
        let text = "SELECT \"mess" as NSString
        #expect(SQLTokenBoundary.segmentStart(in: text, endingAt: 12) == 7)
    }

    @Test("Segment start at a non-token position is the cursor itself")
    func segmentStartAfterSpace() {
        let text = "SELECT " as NSString
        #expect(SQLTokenBoundary.segmentStart(in: text, endingAt: 7) == 7)
    }

    @Test("Segment start at document start")
    func segmentStartAtZero() {
        let text = "mess" as NSString
        #expect(SQLTokenBoundary.segmentStart(in: text, endingAt: 0) == 0)
        #expect(SQLTokenBoundary.segmentStart(in: text, endingAt: 4) == 0)
    }

    @Test("Segment start counts UTF-16 units with multibyte text before the token")
    func segmentStartAfterMultibyteText() {
        let text = "-- ghi chú 🙂\nSELECT mess" as NSString
        let cursor = text.length
        #expect(SQLTokenBoundary.segmentStart(in: text, endingAt: cursor) == cursor - 4)
    }

    @Test("Out-of-bounds cursor is clamped")
    func segmentStartClampsCursor() {
        let text = "mess" as NSString
        #expect(SQLTokenBoundary.segmentStart(in: text, endingAt: 99) == 0)
        #expect(SQLTokenBoundary.segmentStart(in: text, endingAt: -1) == 0)
    }

    @Test("Replacement range ignores a stale stored range and covers the live token")
    func replacementRangeRecoversFromStaleContext() {
        let text = "SELECT mess" as NSString
        let stale = NSRange(location: 9, length: 2)
        let range = SQLTokenBoundary.replacementRange(in: text, cursor: 11, fallback: stale)
        #expect(range == NSRange(location: 7, length: 4))
        let result = text.replacingCharacters(in: range, with: "message")
        #expect(result == "SELECT message")
    }

    @Test("Replacement range falls back to the stored range without a cursor")
    func replacementRangeFallsBackWithoutCursor() {
        let text = "SELECT mess" as NSString
        let stored = NSRange(location: 7, length: 4)
        #expect(SQLTokenBoundary.replacementRange(in: text, cursor: nil, fallback: stored) == stored)
        #expect(SQLTokenBoundary.replacementRange(in: nil, cursor: 11, fallback: stored) == stored)
    }

    @Test("Replacement range after a dot covers only the typed segment")
    func replacementRangeAfterDot() {
        let text = "SELECT users.na FROM users" as NSString
        let range = SQLTokenBoundary.replacementRange(
            in: text, cursor: 15, fallback: NSRange(location: 0, length: 0)
        )
        #expect(range == NSRange(location: 13, length: 2))
        let result = text.replacingCharacters(in: range, with: "name")
        #expect(result == "SELECT users.name FROM users")
    }

    @Test("Empty prefix inserts at the cursor")
    func replacementRangeEmptyPrefix() {
        let text = "SELECT " as NSString
        let range = SQLTokenBoundary.replacementRange(
            in: text, cursor: 7, fallback: NSRange(location: 3, length: 2)
        )
        #expect(range == NSRange(location: 7, length: 0))
    }
}
