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

    // MARK: - Non-ASCII identifiers

    /// The ASCII-only rule read these tokens as empty, so the replacement range collapsed to zero
    /// length and accepting a suggestion inserted beside the typed text instead of replacing it.
    @Test(
        "A non-ASCII token is replaced, not duplicated",
        arguments: [
            ("SELECT 名", "名前", "SELECT 名前"),
            ("SELECT 名前", "名前テーブル", "SELECT 名前テーブル"),
            ("SELECT имя", "имя_клиента", "SELECT имя_клиента"),
            ("SELECT tên", "tên_khach", "SELECT tên_khach"),
            ("SELECT café", "café_id", "SELECT café_id"),
            ("SELECT Ünvan", "Ünvan_kodu", "SELECT Ünvan_kodu")
        ]
    )
    func nonASCIISegmentIsReplaced(typed: String, completion: String, expected: String) {
        let text = typed as NSString
        let range = SQLTokenBoundary.replacementRange(
            in: text, cursor: text.length, fallback: NSRange(location: 0, length: 0)
        )
        #expect(text.replacingCharacters(in: range, with: completion) == expected)
    }

    @Test("A mixed ASCII and non-ASCII token is covered whole")
    func mixedScriptSegment() {
        let text = "SELECT tê" as NSString
        #expect(SQLTokenBoundary.segmentStart(in: text, endingAt: text.length) == 7)
    }

    @Test("A surrogate pair is consumed whole rather than split")
    func surrogatePairSegment() {
        let text = "SELECT 𝕏table" as NSString
        #expect(text.length == 14)
        #expect(SQLTokenBoundary.segmentStart(in: text, endingAt: text.length) == 7)
    }

    @Test("A combining mark stays with the base character it sits on")
    func combiningMarkSegment() {
        let text = "SELECT te\u{0302}n" as NSString
        #expect(SQLTokenBoundary.segmentStart(in: text, endingAt: text.length) == 7)
    }

    @Test("A non-ASCII token still stops at a dot")
    func nonASCIISegmentStopsAtDot() {
        let text = "SELECT 顧客.名" as NSString
        #expect(SQLTokenBoundary.segmentStart(in: text, endingAt: text.length) == 10)
    }

    @Test("Non-identifier punctuation and symbols still end the token")
    func nonASCIIPunctuationEndsSegment() {
        for text in ["SELECT a、b", "SELECT a b", "SELECT a+b", "SELECT a→b"] {
            let ns = text as NSString
            #expect(SQLTokenBoundary.segmentStart(in: ns, endingAt: ns.length) == ns.length - 1)
        }
    }

    /// `$` opens a MongoDB pipeline stage, and `MongoContextAnalyzer` needs the token to start
    /// there, so the wider rule must not adopt it.
    @Test("A dollar sign still ends the token")
    func dollarEndsSegment() {
        let text = "aggregate([{ $match" as NSString
        #expect(SQLTokenBoundary.segmentStart(in: text, endingAt: text.length) == text.length - 5)
    }

    @Test("ASCII segments are unchanged by the wider rule")
    func asciiSegmentsUnchanged() {
        #expect(SQLTokenBoundary.segmentStart(in: "SELECT mess" as NSString, endingAt: 11) == 7)
        #expect(SQLTokenBoundary.segmentStart(in: "SELECT users.na" as NSString, endingAt: 15) == 13)
        #expect(SQLTokenBoundary.segmentStart(in: "SELECT " as NSString, endingAt: 7) == 7)
    }
}
