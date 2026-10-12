import Foundation
@testable import TableProFirebaseCore
import Testing

@Suite("Realtime Database query planning")
struct RealtimeDatabasePlannerTests {
    private func items(_ spec: FirebaseBrowseSpec, types: [String: String] = [:]) throws -> [String] {
        try RealtimeDatabaseQueryPlanner.plan(spec: spec, typeOf: { types[$0] }).queryItems.map { "\($0.name)=\($0.value ?? "")" }
    }

    @Test("A plain page orders by key and reads offset plus limit")
    func plainPage() throws {
        let plan = try RealtimeDatabaseQueryPlanner.plan(spec: FirebaseBrowseSpec(table: "chats", limit: 50, offset: 100), typeOf: noTypes)
        #expect(plan.dropCount == 100)
        #expect(plan.queryItems.map { "\($0.name)=\($0.value ?? "")" } == [#"orderBy="$key""#, "limitToFirst=150"])
    }

    @Test("A descending sort reads from the end")
    func descending() throws {
        let spec = FirebaseBrowseSpec(table: "x", sorts: [FirebaseSortSpec(column: "score", ascending: false)], limit: 10, offset: 0)
        #expect(try items(spec) == [#"orderBy="score""#, "limitToLast=10"])
    }

    @Test("One filter becomes bounds on its own field, typed by the column")
    func filters() throws {
        let equal = FirebaseBrowseSpec(table: "x", filters: [FirebaseFilterSpec(column: "age", op: "=", value: "30")], limit: 5, offset: 0)
        #expect(try items(equal, types: ["age": "number"]) == [#"orderBy="age""#, "equalTo=30", "limitToFirst=5"])
        let zip = FirebaseBrowseSpec(table: "x", filters: [FirebaseFilterSpec(column: "zip", op: ">", value: "021")], limit: 5, offset: 0)
        #expect(try items(zip, types: ["zip": "string"]) == [#"orderBy="zip""#, #"startAfter="021""#, "limitToFirst=5"])
        let key = FirebaseBrowseSpec(table: "x", filters: [FirebaseFilterSpec(column: "$key", op: "BETWEEN", value: "a", secondValue: "m")], limit: 0, offset: 0)
        #expect(try items(key) == [#"orderBy="$key""#, #"endAt="m""#, #"startAt="a""#])
        let prefix = FirebaseBrowseSpec(table: "x", filters: [FirebaseFilterSpec(column: "name", op: "STARTS WITH", value: "Al")], limit: 0, offset: 0)
        #expect(try items(prefix) == [#"orderBy="name""#, "endAt=\"Al\u{F8FF}\"", #"startAt="Al""#])
    }

    @Test("What the API cannot do is refused with the reason")
    func refusals() {
        let two = FirebaseBrowseSpec(table: "x", filters: [
            FirebaseFilterSpec(column: "a", op: "=", value: "1"), FirebaseFilterSpec(column: "b", op: "=", value: "2")
        ], limit: 1, offset: 0)
        #expect(throws: FirebaseError.self) { try RealtimeDatabaseQueryPlanner.plan(spec: two, typeOf: noTypes) }
        let mixed = FirebaseBrowseSpec(table: "x", filters: [FirebaseFilterSpec(column: "a", op: "=", value: "1")],
                                       sorts: [FirebaseSortSpec(column: "b", ascending: true)], limit: 1, offset: 0)
        #expect(throws: FirebaseError.self) { try RealtimeDatabaseQueryPlanner.plan(spec: mixed, typeOf: noTypes) }
        let contains = FirebaseBrowseSpec(table: "x", filters: [FirebaseFilterSpec(column: "a", op: "CONTAINS", value: "1")], limit: 1, offset: 0)
        #expect(throws: FirebaseError.self) { try RealtimeDatabaseQueryPlanner.plan(spec: contains, typeOf: noTypes) }
    }

    @Test("A raw filter is the query string as written, with the page limit added")
    func raw() throws {
        let spec = FirebaseBrowseSpec(table: "x", filters: [FirebaseFilterSpec(column: "__RAW__", op: "", value: #"orderBy="age"&startAt=18"#)], limit: 20, offset: 0)
        #expect(try items(spec) == [#"orderBy="age""#, "startAt=18", "limitToFirst=20"])
    }
}

@Suite("Realtime Database ordering and rows")
struct RealtimeDatabaseRowTests {
    @Test("Integer keys sort numerically before string keys")
    func keyOrder() {
        let keys = ["b", "10", "2", "a", "-1", "007"].sorted(by: RealtimeDatabaseOrdering.keyPrecedes)
        #expect(keys == ["-1", "2", "10", "007", "a", "b"])
    }

    @Test("Values sort null, false, true, numbers, strings, objects")
    func valueOrder() {
        let children: [(key: String, value: FirebaseJSON)] = [
            ("o", .object(["v": .object([:])])), ("s", .object(["v": .string("x")])), ("n", .object(["v": .int(2)])),
            ("d", .object(["v": .double(1.5)])), ("t", .object(["v": .bool(true)])), ("f", .object(["v": .bool(false)])),
            ("z", .object([:]))
        ]
        let sorted = RealtimeDatabaseOrdering.sort(children, order: .child("v"), ascending: true).map(\.key)
        #expect(sorted == ["z", "f", "t", "d", "n", "s", "o"])
    }

    @Test("Object children become columns, plain children a $value column")
    func rows() {
        let rows = RealtimeDatabaseRowSet(children: [
            ("op_1", json(#"{"name": "Ann", "calls": 3, "meta": {"a": 1}}"#)),
            ("op_2", json(#"{"name": "Bo"}"#)),
            ("flag", .bool(true))
        ], nodePath: "/operators")
        #expect(rows.columns == ["$key", "calls", "meta", "name", "$value"])
        #expect(rows.rows[0] == ["op_1", "3", #"{"a":1}"#, "Ann", nil])
        #expect(rows.rows[2] == ["flag", nil, nil, nil, "true"])
        #expect(rows.absentCells[1] == [1, 2, 4])
        #expect(rows.locators == ["operators/op_1", "operators/op_2", "operators/flag"])
        #expect(rows.columnTypes == ["string", "number", "object", "string", "boolean"])
        #expect(rows.cellTypes["operators/op_1"]?["calls"] == "number")
    }

    @Test("A node holding a plain value is one row located at the node")
    func plainNode() {
        let rows = RealtimeDatabaseRowSet(children: [("", .bool(false))], nodePath: "config/maintenance")
        #expect(rows.rows == [["maintenance", "false"]])
        #expect(rows.locators == ["config/maintenance"])
    }

    @Test("Cell edits keep the cell's type")
    func cellEdits() throws {
        #expect(try RealtimeDatabaseCell.value(text: "42", typeName: "string") == .string("42"))
        #expect(try RealtimeDatabaseCell.value(text: "42", typeName: "number") == .int(42))
        #expect(try RealtimeDatabaseCell.value(text: "4.5", typeName: "number") == .double(4.5))
        #expect(try RealtimeDatabaseCell.value(text: "true", typeName: "boolean") == .bool(true))
        #expect(try RealtimeDatabaseCell.value(text: #"{"a":1}"#, typeName: "object") == .object(["a": .int(1)]))
        #expect(try RealtimeDatabaseCell.value(text: "hello", typeName: nil) == .string("hello"))
        #expect(try RealtimeDatabaseCell.value(text: "7", typeName: nil) == .int(7))
        #expect(throws: FirebaseError.self) { try RealtimeDatabaseCell.value(text: "x", typeName: "number") }
    }

    @Test("Keys with forbidden characters are refused")
    func keys() throws {
        try RealtimeDatabasePath.validateKey("operator_1")
        for bad in ["", "a.b", "a/b", "a$", "a#", "[x]"] {
            #expect(throws: FirebaseError.self) { try RealtimeDatabasePath.validateKey(bad) }
        }
    }
}
