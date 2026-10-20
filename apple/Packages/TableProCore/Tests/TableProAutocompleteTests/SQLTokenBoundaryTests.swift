import Foundation
@testable import TableProAutocomplete
import TableProSQLGrammar
import Testing

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

    @Test(
        "Match text drops the identifier quotes the segment carries",
        arguments: [
            ("`cat", "cat"),
            ("\"cat", "cat"),
            ("`category`", "category"),
            ("\"category\"", "category"),
            ("`", ""),
            ("\"", ""),
            ("[ord", "ord"),
            ("[", ""),
            ("cat", "cat"),
            ("", "")
        ]
    )
    func matchTextDropsQuotes(segment: String, expected: String) {
        #expect(SQLTokenBoundary.matchText(of: segment) == expected)
    }

    @Test("Match text does not change what the segment covers")
    func matchTextLeavesTheSegmentAlone() {
        let text = "SELECT \"mess" as NSString
        #expect(SQLTokenBoundary.segmentStart(in: text, endingAt: 12) == 7)
        #expect(SQLTokenBoundary.matchText(of: text.substring(from: 7)) == "mess")
    }

    // The ASCII-only rule read these as empty, so an accepted suggestion landed beside the typed text.
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

    // `MongoContextAnalyzer` needs the token to start at a pipeline stage's `$`.
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

    @Test("An open bracket starts the segment on a bracket grammar", arguments: ["SQL Server", "SQLite"])
    func openBracketStartsTheSegment(engine: String) {
        let text = "SELECT * FROM [ord" as NSString
        #expect(SQLTokenBoundary.segmentStart(in: text, endingAt: 18, grammar: .engine(engine)) == 14)
    }

    // An editor that closes the pair leaves the caret before the close, and the bare name goes between the quotes.
    @Test(
        "A closed quote pair starts the segment after the opening quote",
        arguments: [
            ("SQL Server", "SELECT * FROM [ord]", "SELECT * FROM [orders]"),
            ("SQLite", "SELECT * FROM [ord]", "SELECT * FROM [orders]"),
            ("PostgreSQL", "SELECT * FROM \"ord\"", "SELECT * FROM \"orders\""),
            ("MySQL", "SELECT * FROM `ord`", "SELECT * FROM `orders`")
        ]
    )
    func closedPairStartsAfterTheQuote(engine: String, typed: String, accepted: String) {
        let text = typed as NSString
        let start = SQLTokenBoundary.segmentStart(in: text, endingAt: 18, grammar: .engine(engine))
        #expect(start == 15)
        let range = NSRange(location: start, length: 18 - start)
        #expect(text.replacingCharacters(in: range, with: "orders") == accepted)
    }

    @Test("A quote closed before the caret stays in the segment")
    func quoteClosedBeforeTheCaret() {
        let text = "SELECT * FROM `cat`" as NSString
        #expect(SQLTokenBoundary.segmentStart(in: text, endingAt: text.length, grammar: .engine("MySQL")) == 14)
    }

    @Test("Standard SQL keeps an open quote and never treats a bracket as one")
    func standardSQLSegments() {
        #expect(SQLTokenBoundary.segmentStart(in: "SELECT \"mess" as NSString, endingAt: 12, grammar: .ansi) == 7)
        #expect(SQLTokenBoundary.segmentStart(in: "SELECT * FROM [ord" as NSString, endingAt: 18, grammar: .ansi) == 15)
        #expect(SQLTokenBoundary.segmentStart(in: "SELECT * FROM `ord" as NSString, endingAt: 18, grammar: .ansi) == 14)
    }

    @Test("An opening bracket ends the walk back", arguments: ["SQL Server", "SQLite"])
    func bracketEndsTheWalk(engine: String) {
        let text = "SELECT a[ord" as NSString
        #expect(SQLTokenBoundary.segmentStart(in: text, endingAt: text.length, grammar: .engine(engine)) == 8)
    }
}
