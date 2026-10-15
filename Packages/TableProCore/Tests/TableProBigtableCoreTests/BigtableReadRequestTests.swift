import Foundation
@testable import TableProBigtableCore
import Testing

struct BigtableReadRequestTests {
    private func body(
        _ filters: [BigtableFilterSpec],
        or: Bool = false,
        descending: Bool = false,
        after: String? = nil
    ) throws -> [String: Any]? {
        let spec = BigtableBrowseSpec(table: "t", filters: filters, logicMode: or ? "OR" : "AND", descending: descending, limit: 10, offset: 0)
        return try BigtableReadRequest.body(spec: spec, limit: 10, after: after.map { Data($0.utf8) })
    }

    private func rows(_ filters: [BigtableFilterSpec], or: Bool = false, after: String? = nil) throws -> String {
        jsonText(try #require(try body(filters, or: or, after: after))["rows"] ?? [String: Any]())
    }

    private func filter(_ filters: [BigtableFilterSpec], or: Bool = false) throws -> String {
        jsonText(try #require(try body(filters, or: or))["filter"] ?? [String: Any]())
    }

    private func key(_ op: String, _ value: String, _ second: String? = nil, caseSensitive: Bool = true) -> BigtableFilterSpec {
        BigtableFilterSpec(column: "_key", op: op, value: value, secondValue: second, isCaseSensitive: caseSensitive)
    }

    @Test("A plain page reads the newest cells, with the limit as a string")
    func plain() throws {
        #expect(jsonText(try #require(try body([]))) == #"{"filter":{"cellsPerColumnLimitFilter":1},"rowsLimit":"10"}"#)
    }

    @Test("Key filters become row ranges, intersected under AND")
    func keyRanges() throws {
        #expect(try rows([key("STARTS WITH", "user#")])
            == #"{"rowRanges":[{"endKeyOpen":"\#(b64("user$"))","startKeyClosed":"\#(b64("user#"))"}]}"#)
        #expect(try rows([key(">=", "b"), key("<", "m"), key(">", "c")])
            == #"{"rowRanges":[{"endKeyOpen":"\#(b64("m"))","startKeyOpen":"\#(b64("c"))"}]}"#)
        #expect(try rows([key("IN", "a, b, z"), key("<", "c")]) == #"{"rowKeys":["\#(b64("a"))","\#(b64("b"))"]}"#)
    }

    @Test("A stricter bound keeps its own open or closed end")
    func stricterBoundKeepsItsEnd() throws {
        #expect(try rows([key("STARTS WITH", "user#"), key("<=", "user#5")])
            == #"{"rowRanges":[{"endKeyClosed":"\#(b64("user#5"))","startKeyClosed":"\#(b64("user#"))"}]}"#)
        #expect(try rows([key(">", "a"), key(">=", "b")]) == #"{"rowRanges":[{"startKeyClosed":"\#(b64("b"))"}]}"#)
        #expect(try rows([key(">=", "b"), key(">", "b")]) == #"{"rowRanges":[{"startKeyOpen":"\#(b64("b"))"}]}"#)
    }

    @Test("Filters that admit no key read nothing instead of sending an empty or inverted range")
    func emptySelections() throws {
        #expect(try body([key("<=", "k")], after: "k") == nil)
        #expect(try body([key(">", "m"), key("<", "c")]) == nil)
        #expect(try body([key("=", "a"), key("=", "b")]) == nil)
        #expect(try body([key("=", "a")], after: "a") == nil)
    }

    @Test("A cursor continues after the last key, and a descending read is refused")
    func cursors() throws {
        #expect(try rows([], after: "k9") == #"{"rowRanges":[{"startKeyOpen":"\#(b64("k9"))"}]}"#)
        #expect(throws: BigtableError.self) { try body([], descending: true) }
    }

    @Test("Key filters ORed together become several ranges, and a range the cursor passed is dropped")
    func orRanges() throws {
        #expect(try rows([key("STARTS WITH", "a"), key("=", "q")], or: true, after: "a5")
            == #"{"rowKeys":["\#(b64("q"))"],"rowRanges":[{"endKeyOpen":"\#(b64("b"))","startKeyOpen":"\#(b64("a5"))"}]}"#)
        #expect(try rows([key("STARTS WITH", "a"), key("=", "q")], or: true, after: "b5") == #"{"rowKeys":["\#(b64("q"))"]}"#)
        #expect(try body([key("STARTS WITH", "a"), key("=", "q")], or: true, after: "r") == nil)
    }

    @Test("Base64 items in an IN list each read back as bytes")
    func inListOfBytes() throws {
        #expect(try rows([key("IN", "b64:AAE=, b64:AAI=")]) == #"{"rowKeys":["AAE=","AAI="]}"#)
        let column = try filter([BigtableFilterSpec(column: "cf:a", op: "IN", value: "b64:AAE=, b64:AAI=")])
        #expect(column.contains(b64(#"(?s)^(\x00\x01|\x00\x02)$"#)))
    }

    @Test("A case-insensitive key match runs as a key regex, since a row range is exact")
    func caseInsensitiveKey() throws {
        let object = try #require(try body([key("=", "Alice", caseSensitive: false)]))
        #expect(object["rows"] == nil)
        #expect(jsonText(object["filter"] ?? [:]).contains(#""rowKeyRegexFilter":"\#(b64("(?is)^Alice$"))""#))
    }

    @Test("Case-insensitive text filters fold case, case-sensitive ones do not")
    func caseFolding() throws {
        let insensitive = try filter([BigtableFilterSpec(column: "cf:name", op: "CONTAINS", value: "alice", isCaseSensitive: false)])
        #expect(insensitive.contains(b64("(?is).*alice.*")))
        let sensitive = try filter([BigtableFilterSpec(column: "cf:name", op: "CONTAINS", value: "alice")])
        #expect(sensitive.contains(b64("(?s).*alice.*")))
        let regex = try filter([BigtableFilterSpec(column: "cf:name", op: "REGEX", value: "^a", isCaseSensitive: false)])
        #expect(regex.contains(b64("(?i)^a")))
    }

    @Test("Column filters keep or drop whole rows through conditions")
    func columnConditions() throws {
        let equal = try filter([BigtableFilterSpec(column: "cf:name", op: "=", value: "A.n")])
        #expect(equal.contains(#""familyNameRegexFilter":"^cf$""#))
        #expect(equal.contains(b64(#"(?s)^A\.n$"#)))
        #expect(equal.contains(#""trueFilter":{"passAllFilter":true}"#))
        let missing = try filter([BigtableFilterSpec(column: "cf:name", op: "IS NULL", value: "")])
        #expect(missing.contains(#""falseFilter":{"passAllFilter":true}"#) && !missing.contains("valueRegexFilter"))
        let range = try filter([BigtableFilterSpec(column: "cf:n", op: "BETWEEN", value: "1", secondValue: "9")])
        #expect(range.contains(#""startValueClosed":"\#(b64("1"))""#) && range.contains(#""endValueClosed":"\#(b64("9"))""#))
    }

    @Test("A negative test on a column also needs the column, as in SQL a missing value matches neither side")
    func negativeFiltersNeedTheColumn() throws {
        for op in ["!=", "NOT CONTAINS", "NOT IN", "IS NOT EMPTY"] {
            let text = try filter([BigtableFilterSpec(column: "cf:name", op: op, value: "x")])
            let present = try #require(text.range(of: #""trueFilter":{"passAllFilter":true}"#), "\(op)")
            let excluded = try #require(text.range(of: #""falseFilter":{"passAllFilter":true}"#), "\(op)")
            #expect(present.lowerBound < excluded.lowerBound, "\(op)")
        }
    }

    @Test("Several column filters chain under AND and interleave under OR")
    func combinations() throws {
        let filters = [BigtableFilterSpec(column: "cf:a", op: "=", value: "1"), BigtableFilterSpec(column: "cf:b", op: "CONTAINS", value: "x")]
        #expect(try filter(filters).hasPrefix(#"{"chain":{"filters":[{"chain""#))
        #expect(try filter(filters, or: true).hasPrefix(#"{"chain":{"filters":[{"interleave""#))
    }

    @Test("What Bigtable cannot express is refused with the reason")
    func refusals() {
        #expect(throws: BigtableError.self) {
            try body([key(">", "a"), BigtableFilterSpec(column: "cf:a", op: "=", value: "1")], or: true)
        }
        #expect(throws: BigtableError.self) { try body([BigtableFilterSpec(column: "nocolon", op: "=", value: "1")]) }
        #expect(throws: BigtableError.self) { try body([BigtableFilterSpec(column: "__RAW__", op: "", value: "not json")]) }
        let sorted = BigtableBrowseSpec(table: "t", sortColumn: "cf:a", limit: 1, offset: 0)
        #expect(throws: BigtableError.self) { try BigtableReadRequest.body(spec: sorted, limit: 1, after: nil) }
    }

    @Test("A keys-only read strips values and keeps one cell per row")
    func keysOnly() throws {
        let spec = BigtableBrowseSpec(table: "t", limit: 0, offset: 0)
        let object = try #require(try BigtableReadRequest.body(spec: spec, limit: 500, after: nil, keysOnly: true))
        #expect(jsonText(object["filter"] ?? [:]) == #"{"chain":{"filters":[{"cellsPerRowLimitFilter":1},{"stripValueTransformer":true}]}}"#)
    }

    @Test("A column sample strips values, since only the column names are wanted")
    func columnSample() {
        #expect(jsonText(BigtableReadRequest.columnSample(limit: 50))
            == #"{"filter":{"chain":{"filters":[{"cellsPerColumnLimitFilter":1},{"stripValueTransformer":true}]}},"rowsLimit":"50"}"#)
    }
}
