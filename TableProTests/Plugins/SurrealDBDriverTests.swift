//
//  SurrealDBDriverTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct SurrealQLTests {
    @Test("Identifiers are backtick-quoted only when they need it")
    func identifiers() {
        #expect(SurrealQL.quoteIdentifier("person") == "person")
        #expect(SurrealQL.quoteIdentifier("odd-table") == "`odd-table`")
        #expect(SurrealQL.quoteIdentifier("with space") == "`with space`")
        #expect(SurrealQL.quoteIdentifier("select") == "`select`")
        #expect(SurrealQL.quoteIdentifier("we`ird") == "`we\\`ird`")
    }

    @Test("String literals escape quotes and backslashes")
    func literals() {
        #expect(SurrealQL.stringLiteral("O'Brien") == "'O\\'Brien'")
        #expect(SurrealQL.stringLiteral("back\\slash") == "'back\\\\slash'")
        #expect(SurrealQL.stringLiteral("plain") == "'plain'")
    }

    @Test("Record ids parse from every form SurrealDB emits")
    func recordIds() {
        #expect(SurrealQL.parseRecordId("person:alice") == SurrealRecordID(table: "person", id: .string("alice")))
        #expect(SurrealQL.parseRecordId("person:10") == SurrealRecordID(table: "person", id: .int(10)))
        #expect(SurrealQL.parseRecordId("person:`a:b`") == SurrealRecordID(table: "person", id: .string("a:b")))
        #expect(SurrealQL.parseRecordId("person:\u{27E8}10\u{27E9}") == SurrealRecordID(table: "person", id: .string("10")))
        #expect(SurrealQL.parseRecordId("alice", fallbackTable: "person")
            == SurrealRecordID(table: "person", id: .string("alice")))
        #expect(SurrealQL.parseRecordId("") == nil)
    }

    @Test("A backticked string id is not re-inferred as an int")
    func quotedStringIdStaysString() {
        #expect(SurrealQL.parseRecordId("person:`10`") == SurrealRecordID(table: "person", id: .string("10")))
        #expect(SurrealQL.parseRecordId("person:\u{27E8}10\u{27E9}") == SurrealRecordID(table: "person", id: .string("10")))
        #expect(SurrealQL.parseRecordId("person:10") == SurrealRecordID(table: "person", id: .int(10)))
    }

    @Test("Record ids round-trip through their display literal")
    func recordIdRoundTrip() {
        let ids: [SurrealValue] = [
            .string("alice"),
            .int(10),
            .string("10"),
            .string("a:b"),
            .string("has space"),
        ]
        for id in ids {
            let record = SurrealRecordID(table: "person", id: id)
            let literal = SurrealValue.recordId(record).displayText
            #expect(SurrealQL.parseRecordId(literal) == record, "\(literal) did not round-trip")
        }
    }

    @Test("A record id whose table needs quoting round-trips without changing table")
    func oddTableRoundTrip() {
        let record = SurrealRecordID(table: "a:b", id: .int(1))
        let literal = SurrealValue.recordId(record).displayText
        #expect(literal == "`a:b`:1")
        #expect(SurrealQL.parseRecordId(literal) == record)
    }
}

struct SurrealQueryBuilderTests {
    private let scope = SurrealScope(namespace: "ns", database: "db")

    @Test("Browse emits real, self-scoping SurrealQL")
    func browse() {
        let query = SurrealQueryBuilder.browse(
            table: "person", scope: scope,
            sortColumns: [(column: "name", ascending: false)], limit: 100, offset: 200
        )
        #expect(query.contains("USE NS ns DB db;"))
        #expect(query.contains("SELECT * FROM person"))
        #expect(query.contains("ORDER BY name DESC, id ASC"))
        #expect(query.contains("LIMIT 100 START 200"))
    }

    @Test("A query with no scope omits USE")
    func noScope() {
        let query = SurrealQueryBuilder.browse(
            table: "person", scope: SurrealScope(namespace: nil, database: nil),
            sortColumns: [], limit: 10, offset: 0
        )
        #expect(!query.contains("USE"))
        #expect(query.hasPrefix("SELECT * FROM person"))
    }

    @Test("A hostile filter value never escapes its literal")
    func injection() {
        let hostile = "x'; REMOVE TABLE person; --"
        let query = SurrealQueryBuilder.filtered(
            table: "person", scope: scope,
            filters: [PluginQueryFilter(column: "name", op: "=", value: hostile)],
            logicMode: "and", sortColumns: [], limit: 10, offset: 0
        )
        #expect(query.contains("name = 'x\\'; REMOVE TABLE person; --'"))
        #expect(!query.contains(hostile), "the quote must be escaped so the payload cannot close the literal")
    }

    @Test("Filter operators map onto SurrealQL")
    func operators() throws {
        func clause(_ op: String, _ value: String) throws -> String {
            try SurrealQueryBuilder.whereClause(
                filters: [PluginQueryFilter(column: "c", op: op, value: value)], logicMode: "and"
            ) ?? ""
        }
        #expect(try clause("=", "5") == "c = 5")
        #expect(try clause(">", "5") == "c > 5")
        #expect(try clause("=", "abc") == "c = 'abc'")
        #expect(try clause("=", "true") == "c = true")
        #expect(try clause("IS NULL", "") == "(c = NONE OR c = NULL)")
        #expect(try clause("CONTAINS", "x") == "string::contains(<string> c, 'x')")
        #expect(try clause("STARTS WITH", "x") == "string::starts_with(<string> c, 'x')")
        #expect(try clause("IN", "1, 2") == "c INSIDE [1, 2]")
    }

    @Test("Only a real table:id shape becomes a record literal; look-alikes stay strings")
    func literalRecordDisambiguation() throws {
        func clause(_ value: String) throws -> String {
            try SurrealQueryBuilder.whereClause(
                filters: [PluginQueryFilter(column: "c", op: "=", value: value)], logicMode: "and"
            ) ?? ""
        }
        #expect(try clause("person:tobie") == "c = person:tobie")
        #expect(try clause("12:30") == "c = '12:30'", "a time-shaped value is a string, not a record")
        #expect(try clause("1e5") == "c = 1e5")
        #expect(try clause("null") == "c = NULL")
        #expect(try clause("none") == "c = NONE")
        #expect(try clause("plain") == "c = 'plain'")
    }

    @Test("A hostile filter value cannot escape its literal in any branch")
    func literalBranchesContainPayloads() throws {
        func clause(_ value: String) throws -> String {
            try SurrealQueryBuilder.whereClause(
                filters: [PluginQueryFilter(column: "c", op: "=", value: value)], logicMode: "and"
            ) ?? ""
        }
        // String branch: the closing quote is escaped.
        #expect(try clause("x'; REMOVE TABLE person; --") == "c = 'x\\'; REMOVE TABLE person; --'")
        // Record branch: the id part is backtick-quoted, so ; stays inside the identifier.
        let recordish = try clause("person:a;REMOVE")
        #expect(recordish.hasPrefix("c = person:`") && recordish.hasSuffix("`"))
    }

    @Test("Count uses GROUP ALL")
    func count() {
        let query = SurrealQueryBuilder.count(table: "person", scope: scope, filters: [], logicMode: "and")
        #expect(query.contains("SELECT count() AS total FROM person GROUP ALL;"))
    }

    private func clause(
        _ filter: TableFilter,
        kinds: [String: PluginColumnKind] = [:]
    ) throws -> String? {
        try SurrealQueryBuilder.whereClause(
            filters: [filter.asPluginQueryFilter], logicMode: "and", columnKinds: kinds
        )
    }

    @Test("IS EMPTY matches a missing, null or empty-string field")
    func isEmpty() throws {
        let filter = TableFilter(columnName: "name", filterOperator: .isEmpty)
        #expect(try clause(filter) == "(name = NONE OR name = NULL OR name = '')")
    }

    @Test("IS NOT EMPTY keeps the fields that hold a value, not the empty ones")
    func isNotEmpty() throws {
        let filter = TableFilter(columnName: "name", filterOperator: .isNotEmpty)
        #expect(try clause(filter) == "(name != NONE AND name != NULL AND name != '')")
    }

    @Test("REGEX matches the pattern and passes over a missing or null field")
    func regex() throws {
        let filter = TableFilter(columnName: "name", filterOperator: .regex, value: "^A")
        #expect(try clause(filter) == "(name != NONE AND name != NULL AND string::matches(<string> name, '^A'))")
    }

    @Test("The raw filter row is spliced in as a SurrealQL condition")
    func rawRow() throws {
        let filter = TableFilter(columnName: TableFilter.rawSQLColumn, rawSQL: "age > 10")
        #expect(try clause(filter) == "(age > 10)")
    }

    @Test("A raw condition that only reads keeps its strings, identifiers and function calls")
    func rawConditionThatReads() throws {
        let conditions = [
            "name = 'DELETE me' AND `update` = 1",
            "array::len(array::remove([1, 2], 0)) = 1 OR ->likes->person CONTAINS person:\u{27E8}update\u{27E9}",
            "(age > 10 AND age < 20) OR $session.update = NONE",
            "age IN 10..20 AND string::lowercase(name) = 'a'"
        ]
        for text in conditions {
            let filter = TableFilter(columnName: TableFilter.rawSQLColumn, rawSQL: text)
            #expect(try clause(filter) == "(" + text + ")")
        }
    }

    @Test("A raw condition that could write, end the statement or hide the rest of it is refused")
    func rawConditionThatWrites() {
        let conditions = [
            "age > 1 OR (CREATE probe) = []",
            "true OR { DELETE person }",
            "age > 1 OR (upsert probe:one) = []",
            "fn::wipe() = true",
            "fn ::wipe() = true",
            "fn\n::wipe() = true",
            "http::post('https://example.com') = NONE",
            "http ::post('https://example.com') = NONE",
            "file::delete(bucket:/a.txt) = NONE",
            "NONE ?:UPSERT probe:one SET n += 1",
            "{a:UPSERT probe:one}.a != NONE",
            "age > 1 ?:DELETE person:z",
            "age IN 1..UPSERT probe:one SET n += 1",
            "age > 1; REMOVE TABLE person",
            "age > 1 -- the rest",
            "age > 1 /* note */",
            "age > 1 # note",
            "age > 1) OR (true",
            "name = 'unterminated"
        ]
        for text in conditions {
            let filter = TableFilter(columnName: TableFilter.rawSQLColumn, rawSQL: text)
            #expect(throws: SurrealFilterRefusal.rawConditionNotReadOnly, "\(text)") {
                try clause(filter)
            }
        }
    }

    @Test("A record id named after a writing keyword is refused unless its id is bracketed")
    func rawConditionWithKeywordRecordId() throws {
        let bare = TableFilter(columnName: TableFilter.rawSQLColumn, rawSQL: "id = person:update")
        #expect(throws: SurrealFilterRefusal.rawConditionNotReadOnly) {
            try clause(bare)
        }
        let bracketed = TableFilter(columnName: TableFilter.rawSQLColumn, rawSQL: "id = person:\u{27E8}update\u{27E9}")
        #expect(try clause(bracketed) == "(id = person:\u{27E8}update\u{27E9})")
    }

    @Test("A refused raw condition never reaches the server as SurrealQL")
    func refusedRawConditionThrowsOnTheServer() {
        let raw = TableFilter(columnName: TableFilter.rawSQLColumn, rawSQL: "true OR (DELETE person) = []")
        let query = SurrealQueryBuilder.filtered(
            table: "person", scope: scope, filters: [raw.asPluginQueryFilter],
            logicMode: "and", sortColumns: [], limit: 10, offset: 0
        )
        #expect(query.hasPrefix("USE NS ns DB db;\nTHROW '"))
        #expect(!query.contains("DELETE"))
    }

    @Test("BETWEEN from the filter bar's own encoding uses both bounds")
    func betweenFromAppEncoding() throws {
        let filter = TableFilter(columnName: "age", filterOperator: .between, value: "10", secondValue: "20")
        #expect(filter.asPluginQueryFilter.value == "10,20")
        #expect(try clause(filter, kinds: ["age": .integer]) == "(age >= 10 AND age <= 20)")
    }

    @Test("BETWEEN keeps a comma that belongs to a bound")
    func betweenWithCommaInBound() throws {
        let filter = TableFilter(columnName: "name", filterOperator: .between, value: "Smith, John", secondValue: "Zed")
        #expect(try clause(filter, kinds: ["name": .text]) == "(name >= 'Smith, John' AND name <= 'Zed')")
    }

    @Test("BETWEEN takes the lower bound off by scalars, so a bound ending in a prepend mark keeps its text")
    func betweenWithPrependScalarBeforeTheSeparator() throws {
        let filter = TableFilter(columnName: "code", filterOperator: .between, value: "A\u{0600}", secondValue: "B")
        #expect(try clause(filter, kinds: ["code": .text]) == "(code >= 'A\u{0600}' AND code <= 'B')")
    }

    @Test("BETWEEN without a separate upper bound splits the joined value")
    func betweenFromJoinedValue() throws {
        let clause = try SurrealQueryBuilder.whereClause(
            filters: [PluginQueryFilter(column: "age", op: "BETWEEN", value: "10,20")], logicMode: "and"
        )
        #expect(clause == "(age >= 10 AND age <= 20)")
    }

    @Test("BETWEEN without a separate upper bound splits the joined value by scalars")
    func betweenFromJoinedValueWithPrependScalar() throws {
        let clause = try SurrealQueryBuilder.whereClause(
            filters: [PluginQueryFilter(column: "code", op: "BETWEEN", value: "A\u{0600},B")],
            logicMode: "and",
            columnKinds: ["code": .text]
        )
        #expect(clause == "(code >= 'A\u{0600}' AND code <= 'B')")
    }

    @Test("BETWEEN with one bound is refused")
    func betweenWithOneBound() {
        #expect(throws: SurrealFilterRefusal.incompleteRange) {
            try SurrealQueryBuilder.whereClause(
                filters: [PluginQueryFilter(column: "age", op: "BETWEEN", value: "10")], logicMode: "and"
            )
        }
    }

    @Test("Every operator the filter bar offers has a condition of its own, never an equality")
    func everyFilterBarOperatorIsMapped() throws {
        for filterOperator in FilterOperator.allCases where filterOperator != .equal {
            let filter = TableFilter(columnName: "c", filterOperator: filterOperator, value: "1", secondValue: "2")
            let condition = try clause(filter)
            #expect(condition != "c = 1", "\(filterOperator.rawValue) fell back to an equality")
        }
    }

    @Test("An operator SurrealDB has no condition for is refused")
    func unknownOperatorRefused() {
        #expect(throws: SurrealFilterRefusal.unsupportedOperator("SOUNDS LIKE")) {
            try SurrealQueryBuilder.whereClause(
                filters: [PluginQueryFilter(column: "name", op: "SOUNDS LIKE", value: "x")], logicMode: "and"
            )
        }
    }

    @Test("A refused filter runs as a THROW, so the grid reports it instead of showing no rows")
    func refusedFilterThrowsOnTheServer() {
        let filters = [PluginQueryFilter(column: "name", op: "SOUNDS LIKE", value: "x")]
        let refusal = "USE NS ns DB db;\nTHROW 'SurrealDB cannot filter rows with SOUNDS LIKE.';"
        let browse = SurrealQueryBuilder.filtered(
            table: "person", scope: scope, filters: filters,
            logicMode: "and", sortColumns: [], limit: 10, offset: 0
        )
        let count = SurrealQueryBuilder.count(table: "person", scope: scope, filters: filters, logicMode: "and")
        #expect(browse == refusal)
        #expect(count == refusal)
    }
}

struct SurrealFieldKindTests {
    @Test("Optional fields parse on both versions")
    func optionals() {
        let legacy = SurrealFieldKind.parse("option<int>")
        let modern = SurrealFieldKind.parse("none | int")
        #expect(legacy.base == .int)
        #expect(legacy.isOptional)
        #expect(modern.base == .int)
        #expect(modern.isOptional)

        let plain = SurrealFieldKind.parse("int")
        #expect(plain.base == .int)
        #expect(!plain.isOptional)
    }

    @Test("Record links expose their target table")
    func records() {
        #expect(SurrealFieldKind.parse("record<person>").isRecordLink)
        #expect(SurrealFieldKind.parse("record<person>").recordTable == "person")
        #expect(SurrealFieldKind.parse("none | record<person>").isRecordLink)
        #expect(SurrealFieldKind.parse("option<record<person>>").recordTable == "person")
    }

    @Test("Structured and scalar kinds")
    func kinds() {
        #expect(SurrealFieldKind.parse("array<string>").base == .array)
        #expect(SurrealFieldKind.parse("object").base == .object)
        #expect(SurrealFieldKind.parse("decimal").base == .decimal)
        #expect(SurrealFieldKind.parse("geometry<point>").base == .geometry)
        #expect(SurrealFieldKind.parse("").base == .any)
    }

    @Test("A kind can be inferred from a typed value read back from the server")
    func inferFromValue() {
        #expect(SurrealFieldKind.infer(from: .int(1))?.base == .int)
        #expect(SurrealFieldKind.infer(from: .bool(true))?.base == .bool)
        #expect(SurrealFieldKind.infer(from: .decimal("1.5"))?.base == .decimal)
        #expect(SurrealFieldKind.infer(from: .datetime(seconds: 0, nanoseconds: 0))?.base == .datetime)
        #expect(SurrealFieldKind.infer(from: .recordId(SurrealRecordID(table: "t", id: .int(1))))?.base == .record)
        // NULL/NONE carry no type, so they must not overwrite a learned kind.
        #expect(SurrealFieldKind.infer(from: .null) == nil)
        #expect(SurrealFieldKind.infer(from: .none) == nil)
    }
}

struct SurrealInfoParserTests {
    @Test("Table list reads schemafull on 3.x and full on 2.x")
    func schemafullFlag() {
        let modern = SurrealValue.object([(key: "tables", value: .array([
            .object([
                (key: "name", value: .string("pf")),
                (key: "schemafull", value: .bool(true)),
                (key: "kind", value: .object([(key: "kind", value: .string("NORMAL"))])),
            ]),
        ]))])
        let legacy = SurrealValue.object([(key: "tables", value: .array([
            .object([
                (key: "name", value: .string("pf")),
                (key: "full", value: .bool(true)),
                (key: "kind", value: .object([(key: "kind", value: .string("NORMAL"))])),
            ]),
        ]))])

        #expect(SurrealInfoParser.tables(from: modern).first?.isSchemafull == true)
        #expect(SurrealInfoParser.tables(from: legacy).first?.isSchemafull == true)
    }

    @Test("Relation tables are detected")
    func relations() {
        let value = SurrealValue.object([(key: "tables", value: .array([
            .object([
                (key: "name", value: .string("follows")),
                (key: "schemafull", value: .bool(false)),
                (key: "kind", value: .object([(key: "kind", value: .string("RELATION"))])),
            ]),
        ]))])
        #expect(SurrealInfoParser.tables(from: value).first?.isRelation == true)
    }

    @Test("Nested array fields are dropped on both versions")
    func nestedFields() {
        #expect(SurrealInfoParser.isNestedFieldName("tags.*"))
        #expect(SurrealInfoParser.isNestedFieldName("tags[*]"))
        #expect(!SurrealInfoParser.isNestedFieldName("tags"))

        let value = SurrealValue.object([(key: "fields", value: .array([
            .object([(key: "name", value: .string("tags")), (key: "kind", value: .string("array<string>"))]),
            .object([(key: "name", value: .string("tags.*")), (key: "kind", value: .string("string"))]),
            .object([(key: "name", value: .string("tags[*]")), (key: "kind", value: .string("string"))]),
        ]))])
        let columns = SurrealInfoParser.columns(from: value, isRelation: false)
        #expect(columns.map(\.name) == ["id", "tags"])
        #expect(columns.first?.isPrimaryKey == true)
    }

    @Test("Relation tables pin in and out after id")
    func edgeColumns() {
        let value = SurrealValue.object([(key: "fields", value: .array([
            .object([(key: "name", value: .string("since")), (key: "kind", value: .string("datetime"))]),
        ]))])
        let columns = SurrealInfoParser.columns(from: value, isRelation: true)
        #expect(columns.map(\.name) == ["id", "in", "out", "since"])
    }

    @Test("Index cols read as a 3.x array and a 2.x string")
    func indexes() {
        let modern = SurrealValue.object([(key: "indexes", value: .array([
            .object([
                (key: "name", value: .string("pf_nm")),
                (key: "cols", value: .array([.string("nm")])),
                (key: "index", value: .string("UNIQUE")),
            ]),
        ]))])
        let legacy = SurrealValue.object([(key: "indexes", value: .array([
            .object([
                (key: "name", value: .string("pf_nm")),
                (key: "cols", value: .string("nm")),
                (key: "index", value: .string("UNIQUE")),
            ]),
        ]))])

        #expect(SurrealInfoParser.indexes(from: modern).first?.columns == ["nm"])
        #expect(SurrealInfoParser.indexes(from: legacy).first?.columns == ["nm"])
        #expect(SurrealInfoParser.indexes(from: modern).first?.isUnique == true)
    }
}

struct SurrealRowFlattenerTests {
    @Test("Columns are the union of top-level keys, id first")
    func union() {
        let rows = SurrealValue.array([
            .object([
                (key: "n", value: .int(1)),
                (key: "id", value: .recordId(SurrealRecordID(table: "t", id: .string("a")))),
            ]),
            .object([
                (key: "id", value: .recordId(SurrealRecordID(table: "t", id: .string("b")))),
                (key: "other", value: .string("x")),
            ]),
        ])
        let flattened = SurrealRowFlattener.flatten(rows, length: .display)
        #expect(flattened.columns == ["id", "n", "other"])
        #expect(flattened.rows.count == 2)
    }

    @Test("Ragged rows leave sparse cells empty, not broken")
    func ragged() {
        let rows = SurrealValue.array([
            .object([(key: "a", value: .int(1))]),
            .object([(key: "b", value: .int(2))]),
        ])
        let flattened = SurrealRowFlattener.flatten(rows, length: .display)
        #expect(flattened.columns == ["a", "b"])
        #expect(flattened.rows[0][1] == .null)
        #expect(flattened.rows[1][0] == .null)
    }

    @Test("Nested values become compact JSON text")
    func nested() {
        let rows = SurrealValue.array([
            .object([(key: "meta", value: .object([(key: "k", value: .int(1))]))]),
        ])
        let flattened = SurrealRowFlattener.flatten(rows, length: .display)
        #expect(flattened.rows[0][0] == .text(#"{"k":1}"#))
    }

    @Test("An export row keeps arrays and objects longer than the grid's cap whole")
    func exportRowKeepsLongStructuresWhole() throws {
        let embedding = (0..<1_536).map { Double($0) / 1_024 }
        let vector = SurrealValue.array(embedding.map { .double($0) })
        let rows = SurrealValue.array([
            .object([
                (key: "embedding", value: vector),
                (key: "meta", value: .object([(key: "vector", value: vector)])),
            ]),
        ])
        let row = try #require(SurrealRowFlattener.flatten(rows, length: .whole).rows.first)

        #expect(try parsedJSON(row[0]) as? [Double] == embedding)
        #expect(try parsedJSON(row[1]) as? [String: [Double]] == ["vector": embedding])
    }

    @Test("A grid row still cuts an array longer than the cap")
    func gridRowCutsLongStructures() throws {
        let vector = SurrealValue.array((0..<1_536).map { .double(Double($0) / 1_024) })
        let rows = SurrealValue.array([.object([(key: "embedding", value: vector)])])
        let row = try #require(SurrealRowFlattener.flatten(rows, length: .display).rows.first)
        let text = try #require(row[0].asText)

        #expect(text.hasSuffix("..."))
        #expect((text as NSString).length == SurrealValue.maxSerializedLength + 3)
    }

    private func parsedJSON(_ cell: PluginCellValue) throws -> Any {
        let text = try #require(cell.asText)
        return try JSONSerialization.jsonObject(with: Data(text.utf8))
    }
}

struct SurrealStatementGeneratorTests {
    private let scope = SurrealScope(namespace: "ns", database: "db")
    private let columns = ["id", "name", "age"]
    private let kinds: [String: SurrealFieldKind] = [
        "name": SurrealFieldKind.parse("string"),
        "age": SurrealFieldKind.parse("option<int>"),
    ]

    private func decoded(_ cell: PluginCellValue) -> SurrealValue {
        SurrealCellCoder.value(from: cell)
    }

    private func writes(
        table: String = "person",
        columns: [String]? = nil,
        changes: [PluginRowChange] = [],
        insertedRowData: [Int: [PluginCellValue]] = [:],
        deletedRowIndices: Set<Int> = [],
        insertedRowIndices: Set<Int> = []
    ) throws -> [PluginRowWrite] {
        try SurrealStatementGenerator.rowWrites(
            table: table, scope: scope, columns: columns ?? self.columns, kinds: kinds,
            changes: changes, insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices, insertedRowIndices: insertedRowIndices
        )
    }

    @Test("An update sets only the changed cells and never replaces the record")
    func update() throws {
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 2, columnName: "age", oldValue: .text("30"), newValue: .text("31"))],
            originalRow: [.text("person:alice"), .text("Alice"), .text("30")]
        )
        let write = try #require(try writes(changes: [change]).first)

        #expect(write.statement.contains("UPDATE $p0 SET age = $p1;"))
        #expect(!write.statement.contains("CONTENT"))
        #expect(!write.statement.contains("MERGE"))
        #expect(write.statement.contains("USE NS ns DB db;"))
        #expect(write.rowIndices == [0])

        #expect(decoded(write.parameters[0])
            == .recordId(SurrealRecordID(table: "person", id: .string("alice"))))
        #expect(decoded(write.parameters[1]) == .int(31), "an int column must bind as an int, not a string")
    }

    @Test("The record id is bound, never interpolated")
    func boundRecordId() throws {
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "name", oldValue: .text("a"), newValue: .text("'; REMOVE TABLE person; --"))],
            originalRow: [.text("person:alice"), .text("a"), .null]
        )
        let write = try #require(try writes(changes: [change]).first)
        #expect(!write.statement.contains("REMOVE TABLE"))
        #expect(decoded(write.parameters[1]) == .string("'; REMOVE TABLE person; --"))
    }

    @Test("An insert omits a blank id so the server mints one")
    func insert() throws {
        let write = try #require(try writes(
            insertedRowData: [0: [.text(""), .text("Carol"), .text("22")]], insertedRowIndices: [0]
        ).first)
        #expect(write.statement.contains("CREATE person SET name = $p0, age = $p1;"))
        #expect(decoded(write.parameters[1]) == .int(22))
        #expect(write.rowIndices == [0])
    }

    @Test("An insert with an explicit id binds it as a record id")
    func insertWithId() throws {
        let write = try #require(try writes(
            insertedRowData: [0: [.text("person:carol"), .text("Carol"), .null]], insertedRowIndices: [0]
        ).first)
        #expect(write.statement.contains("CREATE $p0 SET name = $p1;"))
        #expect(decoded(write.parameters[0])
            == .recordId(SurrealRecordID(table: "person", id: .string("carol"))))
    }

    @Test("A delete addresses the record directly")
    func delete() throws {
        let change = PluginRowChange(
            rowIndex: 0, type: .delete, cellChanges: [],
            originalRow: [.text("person:alice"), .text("Alice"), .text("30")]
        )
        let write = try #require(try writes(changes: [change], deletedRowIndices: [0]).first)
        #expect(write.statement.contains("DELETE $p0;"))
        #expect(write.parameters.count == 1)
        #expect(write.rowIndices == [0])
    }

    @Test("Each write names the row it carries out")
    func eachWriteNamesItsRow() throws {
        let update = PluginRowChange(
            rowIndex: 3,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "name", oldValue: .text("A"), newValue: .text("B"))],
            originalRow: [.text("person:a"), .text("A"), .null]
        )
        let delete = PluginRowChange(
            rowIndex: 5, type: .delete, cellChanges: [],
            originalRow: [.text("person:b"), .text("B"), .null]
        )
        let all = try writes(
            changes: [update, delete],
            insertedRowData: [7: [.text(""), .text("C"), .null]],
            deletedRowIndices: [5],
            insertedRowIndices: [7]
        )
        #expect(all.map(\.rowIndices) == [[3], [7], [5]])
    }

    @Test("The auto-id marker on insert lets the server mint the id")
    func autoDefaultInsertId() throws {
        let write = try #require(try writes(
            insertedRowData: [0: [.text("__DEFAULT__"), .text("Carol"), .text("22")]], insertedRowIndices: [0]
        ).first)
        #expect(write.statement.contains("CREATE person SET"))
        #expect(!write.statement.contains("__DEFAULT__"))
        #expect(!write.statement.contains("person:__DEFAULT__"))
    }

    @Test("The auto-id marker on an updated field is skipped, never written literally")
    func autoDefaultUpdateField() throws {
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "name", oldValue: .text("Alice"), newValue: .text("__DEFAULT__"))],
            originalRow: [.text("person:alice"), .text("Alice"), .text("30")]
        )
        #expect(try writes(changes: [change]).isEmpty, "an all-default update produces no statement, not a literal write")
    }

    @Test("An update with no cell changes has nothing to write and is not refused")
    func emptyUpdate() throws {
        let probe = PluginRowChange(rowIndex: 0, type: .update, cellChanges: [], originalRow: nil)
        #expect(try writes(changes: [probe]).isEmpty)
    }

    @Test("An edit to the id column is refused, never dropped")
    func immutableId() {
        let change = PluginRowChange(
            rowIndex: 4,
            type: .update,
            cellChanges: [(columnIndex: 0, columnName: "id", oldValue: .text("person:a"), newValue: .text("person:b"))],
            originalRow: [.text("person:a"), .text("Alice"), .null]
        )
        #expect(throws: PluginRowWriteRefusal(rowIndex: 4, reason: "A record's id cannot be edited.")) {
            try writes(changes: [change])
        }
    }

    @Test("An edit to in or out beside another field is refused, never saved without it", arguments: ["in", "out"])
    func edgeEndpointEditIsRefused(column: String) throws {
        let edgeColumns = ["id", "in", "out", "weight"]
        let columnIndex = try #require(edgeColumns.firstIndex(of: column))
        let change = PluginRowChange(
            rowIndex: 2,
            type: .update,
            cellChanges: [
                (columnIndex: columnIndex, columnName: column, oldValue: .text("person:a"), newValue: .text("person:c")),
                (columnIndex: 3, columnName: "weight", oldValue: .text("1"), newValue: .text("2"))
            ],
            originalRow: [.text("likes:x"), .text("person:a"), .text("person:b"), .text("1")]
        )
        let error = #expect(throws: PluginRowWriteRefusal.self) {
            try writes(table: "likes", columns: edgeColumns, changes: [change])
        }
        #expect(error?.rowIndex == 2)
        #expect(error?.reason.contains("'\(column)'") == true)
    }

    private let documentColumns = ["id", "tags", "meta"]
    private let documentKinds: [String: SurrealFieldKind] = ["tags": SurrealFieldKind.parse("array<string>")]

    private func tagArray(count: Int) -> String {
        SurrealValue.array((0..<count).map { .string("tag-\($0)") }).displayText
    }

    private func shortenedTags() -> String {
        tagArray(count: 1_500)
    }

    private func shortenedRefusal(_ column: String) -> PluginRowWriteRefusal {
        PluginRowWriteRefusal(
            rowIndex: 0,
            reason: "The value in \(column) is shortened for display, so saving it would store only the part shown. "
                + "Change this field with a query."
        )
    }

    private func documentEdit(
        _ column: String,
        from old: String,
        to new: PluginCellValue,
        beside original: [PluginCellValue] = [.text("post:one"), .null, .null]
    ) -> PluginRowChange {
        let columnIndex = documentColumns.firstIndex(of: column) ?? 0
        var originalRow = original
        originalRow[columnIndex] = .text(old)
        return PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: columnIndex, columnName: column, oldValue: .text(old), newValue: new)],
            originalRow: originalRow
        )
    }

    private func documentWrite(_ change: PluginRowChange) throws -> PluginRowWrite {
        let writes = try SurrealStatementGenerator.rowWrites(
            table: "post", scope: scope, columns: documentColumns, kinds: documentKinds,
            changes: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )
        return try #require(writes.first)
    }

    @Test("An edit to an array shortened for display is refused rather than saved as the fragment")
    func updateRefusesAShortenedArray() throws {
        let shortened = shortenedTags()
        try #require(shortened.hasSuffix("..."))
        let edited = shortened.replacingOccurrences(of: "\"tag-0\"", with: "\"tag-Z\"")
        #expect(throws: shortenedRefusal("tags")) {
            try documentWrite(documentEdit("tags", from: shortened, to: .text(edited)))
        }
    }

    @Test("Text appended to a schemaless array shortened for display is refused")
    func updateRefusesTextAppendedToAShortenedArray() throws {
        let shortened = shortenedTags()
        try #require(shortened.hasSuffix("..."))
        let appended = String(shortened.dropLast(3)) + #","new"]"#
        #expect(throws: shortenedRefusal("meta")) {
            try documentWrite(documentEdit("meta", from: shortened, to: .text(appended)))
        }
    }

    @Test("A new row carrying a schemaless value shortened right after an object is refused")
    func insertRefusesAValueShortenedAfterAnObject() throws {
        let shortened = SurrealValue.array(
            Array(repeating: .object([(key: "k", value: .string("v"))]), count: 1_500)
        ).displayText
        try #require(shortened.hasSuffix("}..."))
        #expect(throws: shortenedRefusal("meta")) {
            try SurrealStatementGenerator.rowWrites(
                table: "post", scope: scope, columns: documentColumns, kinds: documentKinds,
                changes: [PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)],
                insertedRowData: [0: [.text(""), .null, .text(shortened)]],
                deletedRowIndices: [],
                insertedRowIndices: [0]
            )
        }
    }

    @Test("A complete array written over one shortened for display is refused, since it may be the shown part closed")
    func updateRefusesACompleteArrayWrittenOverAShortenedOne() throws {
        let shownPart = tagArray(count: 800)
        try #require(!shownPart.hasSuffix("..."))
        #expect(throws: shortenedRefusal("tags")) {
            try documentWrite(documentEdit("tags", from: shortenedTags(), to: .text(shownPart)))
        }
    }

    @Test("NULL written over a value shortened for display clears the field")
    func updateWritesNullOverAShortenedValue() throws {
        let write = try documentWrite(documentEdit("tags", from: shortenedTags(), to: .null))
        #expect(write.statement.contains("UPDATE $p0 SET tags = $p1;"))
        #expect(decoded(write.parameters[1]) == .null)
    }

    @Test("An edit to another field of a row holding a shortened value is written")
    func updateWritesAnotherFieldBesideAShortenedValue() throws {
        let change = documentEdit(
            "meta", from: "0", to: .text("1"), beside: [.text("post:one"), .text(shortenedTags()), .null]
        )
        let write = try documentWrite(change)
        #expect(write.statement.contains("UPDATE $p0 SET meta = $p1;"))
        #expect(decoded(write.parameters[1]) == .int(1))
    }
}

struct SurrealCellCoderTests {
    @Test("Text coerces to the column's declared type")
    func typed() {
        func value(_ text: String, _ kind: String) -> SurrealValue {
            SurrealCellCoder.value(from: .text(text), kind: SurrealFieldKind.parse(kind))
        }
        #expect(value("31", "int") == .int(31))
        #expect(value("1.5", "float") == .double(1.5))
        #expect(value("12.345", "decimal") == .decimal("12.345"))
        #expect(value("true", "bool") == .bool(true))
        #expect(value("31", "string") == .string("31"))
        #expect(value("person:alice", "record<person>")
            == .recordId(SurrealRecordID(table: "person", id: .string("alice"))))
        #expect(value(#"{"a":1}"#, "object") == .object([(key: "a", value: .int(1))]))
        #expect(value("2024-09-15T12:34:56.789Z", "datetime")
            == .datetime(seconds: 1_726_403_696, nanoseconds: 789_000_000))
        #expect(value("1h30m", "duration") == .duration(seconds: 5_400, nanoseconds: 0))
    }

    @Test("With no known kind, numeric and bool text is typed, not left a string")
    func fallbackInference() {
        func value(_ text: String) -> SurrealValue {
            SurrealCellCoder.value(from: .text(text), kind: nil)
        }
        #expect(value("31") == .int(31))
        #expect(value("true") == .bool(true))
        #expect(value("false") == .bool(false))
        #expect(value("hello") == .string("hello"))
        #expect(value(#"{"a":1}"#) == .object([(key: "a", value: .int(1))]))
        // A leading-zero string is not an int, so it stays a string.
        #expect(value("007") == .string("007"))
    }

    @Test("An empty cell in an optional column becomes NONE")
    func empties() {
        #expect(SurrealCellCoder.value(from: .null, kind: SurrealFieldKind.parse("option<int>")) == .none)
        #expect(SurrealCellCoder.value(from: .text(""), kind: SurrealFieldKind.parse("option<int>")) == .none)
        #expect(SurrealCellCoder.value(from: .text(""), kind: SurrealFieldKind.parse("string")) == .string(""))
    }

    @Test("Parameters survive the PluginCellValue boundary")
    func parameters() {
        let values: [SurrealValue] = [
            .recordId(SurrealRecordID(table: "t", id: .int(1))),
            .int(42),
            .decimal("1.5"),
            .none,
        ]
        for value in values {
            #expect(SurrealCellCoder.value(from: SurrealCellCoder.parameter(value)) == value)
        }
    }

    @Test("Plain text and raw bytes are not mistaken for encoded parameters")
    func rawCells() {
        #expect(SurrealCellCoder.value(from: .text("hello")) == .string("hello"))
        #expect(SurrealCellCoder.value(from: .bytes(Data([0x01, 0x02]))) == .bytes(Data([0x01, 0x02])))
        #expect(SurrealCellCoder.value(from: .null) == .null)
    }
}

struct SurrealDBConnectionConfigTests {
    private func config(_ level: String, namespace: String = "ns", extra: [String: String] = [:]) -> SurrealDBConnectionConfig {
        var fields = ["sdbAuthLevel": level]
        fields.merge(extra) { _, new in new }
        return SurrealDBConnectionConfig(config: DriverConnectionConfig(
            host: "localhost", port: 8_000, username: "root", password: "secret",
            database: namespace, ssl: SSLConfiguration(), additionalFields: fields
        ))
    }

    @Test("Each auth level demands the fields it needs")
    func validation() throws {
        try config("root").validate()
        #expect(throws: SurrealDBError.self) { try config("namespace", namespace: "").validate() }
        try config("namespace").validate()
        #expect(throws: SurrealDBError.self) { try config("database").validate() }
        try config("database", extra: ["sdbDatabase": "db"]).validate()
        #expect(throws: SurrealDBError.self) { try config("record", extra: ["sdbDatabase": "db"]).validate() }
        try config("record", extra: ["sdbDatabase": "db", "sdbAccess": "user"]).validate()
        #expect(throws: SurrealDBError.self) { try config("token").validate() }
        try config("token", extra: ["sdbToken": "jwt"]).validate()
    }

    @Test("SurrealDB 1.x is rejected, 2.x and 3.x are supported")
    func versionGate() {
        #expect(SurrealServerVersion.parse("surrealdb/3.2.1")?.major == 3)
        #expect(SurrealServerVersion.parse("surrealdb-2.6.5")?.major == 2)
        #expect(SurrealServerVersion.isSupported("surrealdb-2.6.5"))
        #expect(SurrealServerVersion.isSupported("surrealdb/3.2.1"))
        #expect(!SurrealServerVersion.isSupported("surrealdb-1.5.6"))
    }

    @Test("The endpoint follows the TLS setting")
    func endpoint() {
        #expect(config("root").baseURL?.absoluteString == "http://localhost:8000")

        let secure = SurrealDBConnectionConfig(config: DriverConnectionConfig(
            host: "db.example.com", port: 443, username: "u", password: "p",
            database: "ns", ssl: SSLConfiguration(mode: .required), additionalFields: [:]
        ))
        #expect(secure.baseURL?.absoluteString == "https://db.example.com:443")
        #expect(secure.skipTLSVerify, "Required without CA verification must not verify the certificate")

        let verified = SurrealDBConnectionConfig(config: DriverConnectionConfig(
            host: "db.example.com", port: 443, username: "u", password: "p",
            database: "ns", ssl: SSLConfiguration(mode: .verifyIdentity), additionalFields: [:]
        ))
        #expect(!verified.skipTLSVerify)
    }
}
