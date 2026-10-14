import Foundation
@testable import TableProBigtableCore
import Testing

private func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
private func json(_ text: String) -> Any { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? [:] }

@Suite("Bigtable chunk assembly")
struct BigtableChunkAssemblerTests {
    @Test("Family and qualifier carry over, split values join, and only committed rows count")
    func assembly() throws {
        let response = json("""
        [{"chunks": [
          {"rowKey": "\(b64("r1"))", "familyName": "cf", "qualifier": "\(b64("a"))", "timestampMicros": "10", "value": "\(b64("he"))", "valueSize": 5},
          {"value": "\(b64("llo"))"},
          {"qualifier": "\(b64("b"))", "timestampMicros": "10", "value": "\(b64("x"))", "commitRow": true}
        ]},
        {"chunks": [
          {"rowKey": "\(b64("r2"))", "familyName": "cf", "qualifier": "\(b64("a"))", "timestampMicros": "1", "value": "\(b64("old"))"},
          {"resetRow": true},
          {"rowKey": "\(b64("r2"))", "familyName": {"value": "cf"}, "qualifier": "\(b64("a"))", "timestampMicros": "2", "value": "\(b64("new"))", "commitRow": true}
        ]}]
        """)
        let rows = try BigtableChunkAssembler.rows(fromResponse: response)
        let a = BigtableColumn(family: "cf", qualifier: Data("a".utf8))
        #expect(rows.map(\.key) == [Data("r1".utf8), Data("r2".utf8)])
        #expect(rows[0].cells[a]?.value == Data("hello".utf8))
        #expect(rows[0].cells[BigtableColumn(family: "cf", qualifier: Data("b".utf8))]?.value == Data("x".utf8))
        #expect(rows[1].cells[a] == BigtableCell(value: Data("new".utf8), timestampMicros: 2))
    }

    @Test("A response that stops inside a row is refused")
    func truncated() {
        let response = json("""
        [{"chunks": [{"rowKey": "\(b64("r1"))", "familyName": "cf", "qualifier": "\(b64("a"))", "timestampMicros": "1", "value": "\(b64("v"))"}]}]
        """)
        #expect(throws: BigtableError.self) { try BigtableChunkAssembler.rows(fromResponse: response) }
    }

    @Test("Rows lay out with _key first, columns in order, and missing cells absent")
    func rowSet() {
        let a = BigtableColumn(family: "cf", qualifier: Data("a".utf8))
        let z = BigtableColumn(family: "meta", qualifier: Data([0xFF, 0x00]))
        let set = BigtableRowSet(rows: [
            BigtableRow(key: Data("k1".utf8), cells: [a: BigtableCell(value: Data("v".utf8), timestampMicros: 1)]),
            BigtableRow(key: Data([0x00, 0x01]), cells: [z: BigtableCell(value: Data([0xC3]), timestampMicros: 1)])
        ])
        #expect(set.columns == ["_key", "cf:a", "meta:b64:/wA="])
        #expect(set.rows[0] == [.text("k1"), .text("v"), .absent])
        #expect(set.rows[1] == [.text("b64:AAE="), .absent, .bytes(Data([0xC3]))])
        #expect(set.absentCells == [0: [2], 1: [1]])
        #expect(set.locators == [b64("k1"), Data([0x00, 0x01]).base64EncodedString()])
    }
}

@Suite("Bigtable bytes and columns")
struct BigtableBytesTests {
    @Test("Printable text shows as itself, anything else as b64 that reads back")
    func displayRoundTrip() throws {
        for data in [Data("user#42".utf8), Data([0, 1, 255]), Data("b64:looks-tagged".utf8), Data("line\u{07}bell".utf8)] {
            #expect(try BigtableBytes.parse(BigtableBytes.display(data)) == data)
        }
        #expect(BigtableBytes.display(Data("user#42".utf8)) == "user#42")
        #expect(throws: BigtableError.self) { try BigtableBytes.parse("b64:***") }
    }

    @Test("Prefix end increments the last byte that can grow")
    func prefixEnd() {
        #expect(BigtableBytes.prefixEnd(Data("ab".utf8)) == Data("ac".utf8))
        #expect(BigtableBytes.prefixEnd(Data([0x61, 0xFF])) == Data([0x62]))
        #expect(BigtableBytes.prefixEnd(Data([0xFF, 0xFF])) == nil)
    }

    @Test("Regex literals escape operators and non-printable bytes")
    func regexLiteral() {
        #expect(BigtableBytes.regexText(Data("a.b*(c)".utf8)) == #"a\.b\*\(c\)"#)
        #expect(BigtableBytes.regexText(Data([0x00, 0x41])) == #"\x00A"#)
    }

    @Test("A column name splits at its first colon")
    func columnNames() throws {
        let column = try BigtableColumn(name: "cf:a:b")
        #expect(column.family == "cf" && column.qualifier == Data("a:b".utf8))
        #expect(try BigtableColumn(name: "cf:b64:/wA=").qualifier == Data([0xFF, 0x00]))
        #expect(throws: BigtableError.self) { try BigtableColumn(name: "nocolon") }
        #expect(throws: BigtableError.self) { try BigtableColumn(name: ":q") }
    }
}

@Suite("Bigtable read requests")
struct BigtableReadRequestTests {
    private func body(_ filters: [BigtableFilterSpec], or: Bool = false, descending: Bool = false, after: String? = nil) throws -> [String: Any] {
        let spec = BigtableBrowseSpec(table: "t", filters: filters, logicMode: or ? "OR" : "AND", descending: descending, limit: 10, offset: 0)
        return try BigtableReadRequest.body(spec: spec, limit: 10, after: after.map { Data($0.utf8) })
    }

    private func text(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    }

    @Test("A plain page reads the newest cells, with the limit as a string")
    func plain() throws {
        #expect(text(try body([])) == #"{"filter":{"cellsPerColumnLimitFilter":1},"rowsLimit":"10"}"#)
    }

    @Test("Key filters become row ranges, intersected under AND")
    func keyRanges() throws {
        let prefix = try body([BigtableFilterSpec(column: "_key", op: "STARTS WITH", value: "user#")])
        #expect(text(prefix["rows"] ?? [:]) == #"{"rowRanges":[{"endKeyOpen":"\#(b64("user$"))","startKeyClosed":"\#(b64("user#"))"}]}"#)
        let both = try body([
            BigtableFilterSpec(column: "_key", op: ">=", value: "b"),
            BigtableFilterSpec(column: "_key", op: "<", value: "m"),
            BigtableFilterSpec(column: "_key", op: ">", value: "c")
        ])
        #expect(text(both["rows"] ?? [:]) == #"{"rowRanges":[{"endKeyOpen":"\#(b64("m"))","startKeyOpen":"\#(b64("c"))"}]}"#)
        let exact = try body([BigtableFilterSpec(column: "_key", op: "IN", value: "a, b, z"), BigtableFilterSpec(column: "_key", op: "<", value: "c")])
        #expect(text(exact["rows"] ?? [:]) == #"{"rowKeys":["\#(b64("a"))","\#(b64("b"))"]}"#)
    }

    @Test("A cursor continues after the last key, and a descending read is refused")
    func cursors() throws {
        #expect(text(try body([], after: "k9")["rows"] ?? [:]) == #"{"rowRanges":[{"startKeyOpen":"\#(b64("k9"))"}]}"#)
        #expect(throws: BigtableError.self) { try body([], descending: true) }
    }

    @Test("Key filters ORed together become several ranges, cut by the cursor")
    func orRanges() throws {
        let rows = try body([
            BigtableFilterSpec(column: "_key", op: "STARTS WITH", value: "a"),
            BigtableFilterSpec(column: "_key", op: "=", value: "q")
        ], or: true, after: "a5")["rows"] as? [String: Any]
        #expect(text(rows ?? [:]) == #"{"rowKeys":["\#(b64("q"))"],"rowRanges":[{"endKeyOpen":"\#(b64("b"))","startKeyOpen":"\#(b64("a5"))"}]}"#)
    }

    @Test("Column filters keep or drop whole rows through conditions")
    func columnConditions() throws {
        let equal = try body([BigtableFilterSpec(column: "cf:name", op: "=", value: "A.n")])
        let filter = text(equal["filter"] ?? [:])
        #expect(filter.contains(#""familyNameRegexFilter":"^cf$""#))
        #expect(filter.contains(b64(#"(?s)^A\.n$"#)))
        #expect(filter.contains(#""trueFilter":{"passAllFilter":true}"#))
        let missing = text(try body([BigtableFilterSpec(column: "cf:name", op: "IS NULL", value: "")])["filter"] ?? [:])
        #expect(missing.contains(#""falseFilter":{"passAllFilter":true}"#) && !missing.contains("valueRegexFilter"))
        let range = text(try body([BigtableFilterSpec(column: "cf:n", op: "BETWEEN", value: "1", secondValue: "9")])["filter"] ?? [:])
        #expect(range.contains(#""startValueClosed":"\#(b64("1"))""#) && range.contains(#""endValueClosed":"\#(b64("9"))""#))
    }

    @Test("Several column filters chain under AND and interleave under OR")
    func combinations() throws {
        let filters = [BigtableFilterSpec(column: "cf:a", op: "=", value: "1"), BigtableFilterSpec(column: "cf:b", op: "CONTAINS", value: "x")]
        #expect(text(try body(filters)["filter"] ?? [:]).hasPrefix(#"{"chain":{"filters":[{"chain""#))
        #expect(text(try body(filters, or: true)["filter"] ?? [:]).hasPrefix(#"{"chain":{"filters":[{"interleave""#))
    }

    @Test("What Bigtable cannot express is refused with the reason")
    func refusals() {
        #expect(throws: BigtableError.self) {
            try body([BigtableFilterSpec(column: "_key", op: ">", value: "a"), BigtableFilterSpec(column: "cf:a", op: "=", value: "1")], or: true)
        }
        #expect(throws: BigtableError.self) { try body([BigtableFilterSpec(column: "nocolon", op: "=", value: "1")]) }
        #expect(throws: BigtableError.self) { try body([BigtableFilterSpec(column: "__RAW__", op: "", value: "not json")]) }
        let sorted = BigtableBrowseSpec(table: "t", sortColumn: "cf:a", limit: 1, offset: 0)
        #expect(throws: BigtableError.self) { try BigtableReadRequest.body(spec: sorted, limit: 1, after: nil) }
    }

    @Test("An empty key list asks for nothing and is skipped")
    func asksForNothing() throws {
        let impossible = try body([BigtableFilterSpec(column: "_key", op: "=", value: "a"), BigtableFilterSpec(column: "_key", op: "=", value: "b")])
        #expect(BigtableReadRequest.asksForNothing(impossible))
        #expect(!BigtableReadRequest.asksForNothing(try body([])))
    }

    @Test("A keys-only read strips values and keeps one cell per row")
    func keysOnly() throws {
        let spec = BigtableBrowseSpec(table: "t", limit: 0, offset: 0)
        let object = try BigtableReadRequest.body(spec: spec, limit: 500, after: nil, keysOnly: true)
        #expect(text(object["filter"] ?? [:]) == #"{"chain":{"filters":[{"cellsPerRowLimitFilter":1},{"stripValueTransformer":true}]}}"#)
    }
}

@Suite("Bigtable statements and settings")
struct BigtableStatementTests {
    @Test("Request lines read table, key, column, query and body")
    func requests() throws {
        let get = try BigtableRequest.parse("get events/user#42")
        #expect(get.verb == .get && get.table == "events" && get.key == Data("user#42".utf8))
        let quoted = try BigtableRequest.parse(#"DELETE events/"a b/c" profile:name"#)
        #expect(quoted.key == Data("a b/c".utf8) && quoted.column == "profile:name")
        let scan = try BigtableRequest.parse("SCAN events/user#?limit=20")
        #expect(scan.key == Data("user#".utf8) && scan.limit == 20)
        let all = try BigtableRequest.parse("SCAN events/")
        #expect(all.table == "events" && all.key == nil)
        let put = try BigtableRequest.parse(#"PUT events/b64:AAE= {"cf:a": "1"}"#)
        #expect(put.key == Data([0, 1]) && put.body == #"{"cf:a": "1"}"#)
        let read = try BigtableRequest.parse(#"READ events {"rowsLimit": "5"}"#)
        #expect(read.table == "events" && read.body == #"{"rowsLimit": "5"}"#)
    }

    @Test("Malformed requests explain the syntax")
    func malformed() {
        for text in ["SELECT * FROM t", "GET events/", "PUT events/k", #"GET events/"open"#, "READ events"] {
            #expect(throws: BigtableError.self) { try BigtableRequest.parse(text) }
        }
    }

    @Test("A request reads back from its own text, quoting keys that need it")
    func roundTrip() throws {
        for key in [Data("user#42".utf8), Data("a b".utf8), Data([0xFF]), Data("x/y".utf8)] {
            let request = BigtableRequest(verb: .delete, table: "events", key: key, column: "cf:a")
            #expect(try BigtableRequest.parse(request.text(defaultTable: nil)) == request)
        }
        let spec = BigtableBrowseSpec(table: "t", filters: [BigtableFilterSpec(column: "_key", op: "=", value: "k")], limit: 5, offset: 10)
        #expect(try BigtableStatement.parse(BigtableStatement.encode(spec)) == .browse(spec))
    }

    @Test("The read-only gate sees reads, writes and deletes")
    func classify() {
        #expect(BigtableStatementClassifier.classify(BigtableStatement.encode(BigtableBrowseSpec(table: "t", limit: 1, offset: 0))) == .read)
        #expect(BigtableStatementClassifier.classify("SCAN events/a") == .read)
        #expect(BigtableStatementClassifier.classify(#"READ events {}"#) == .read)
        #expect(BigtableStatementClassifier.classify(#"PUT events/k {"cf:a": "1"}"#) == .write)
        #expect(BigtableStatementClassifier.classify("DELETE events/k") == .destructive)
        #expect(BigtableStatementClassifier.classify("DROP TABLE events") == .write)
    }

    @Test("Settings take the project from the credential and refuse IDs that would change the path")
    func settings() throws {
        let parsed = try BigtableConnectionSettings.parse(fields: ["btInstanceId": "ea-bt-01"], credentialProject: "my-proj")
        #expect(parsed.projectId == "my-proj" && parsed.instanceId == "ea-bt-01" && parsed.authMethod == .serviceAccount)
        #expect(throws: BigtableError.self) { try BigtableConnectionSettings.parse(fields: [:]) }
        #expect(throws: BigtableError.self) { try BigtableConnectionSettings.parse(fields: ["btProjectId": "p-123", "btInstanceId": "../x"]) }
        #expect(throws: BigtableError.self) { try BigtableConnectionSettings.parse(fields: ["btProjectId": "Bad Project"]) }
    }
}
