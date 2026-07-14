//
//  SurrealDBDriverTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("SurrealDB - SurrealQL escaping")
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

@Suite("SurrealDB - query builder")
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
            filters: [(column: "name", op: "=", value: hostile)],
            logicMode: "and", sortColumns: [], limit: 10, offset: 0
        )
        #expect(query.contains("name = 'x\\'; REMOVE TABLE person; --'"))
        #expect(!query.contains(hostile), "the quote must be escaped so the payload cannot close the literal")
    }

    @Test("Filter operators map onto SurrealQL")
    func operators() {
        func clause(_ op: String, _ value: String) -> String {
            SurrealQueryBuilder.whereClause(
                filters: [(column: "c", op: op, value: value)], logicMode: "and"
            ) ?? ""
        }
        #expect(clause("=", "5") == "c = 5")
        #expect(clause(">", "5") == "c > 5")
        #expect(clause("=", "abc") == "c = 'abc'")
        #expect(clause("=", "true") == "c = true")
        #expect(clause("IS NULL", "") == "(c = NONE OR c = NULL)")
        #expect(clause("CONTAINS", "x") == "string::contains(<string> c, 'x')")
        #expect(clause("STARTS WITH", "x") == "string::starts_with(<string> c, 'x')")
        #expect(clause("IN", "1, 2") == "c INSIDE [1, 2]")
    }

    @Test("Only a real table:id shape becomes a record literal; look-alikes stay strings")
    func literalRecordDisambiguation() {
        func clause(_ value: String) -> String {
            SurrealQueryBuilder.whereClause(
                filters: [(column: "c", op: "=", value: value)], logicMode: "and"
            ) ?? ""
        }
        #expect(clause("person:tobie") == "c = person:tobie")
        #expect(clause("12:30") == "c = '12:30'", "a time-shaped value is a string, not a record")
        #expect(clause("1e5") == "c = 1e5")
        #expect(clause("null") == "c = NULL")
        #expect(clause("none") == "c = NONE")
        #expect(clause("plain") == "c = 'plain'")
    }

    @Test("A hostile filter value cannot escape its literal in any branch")
    func literalBranchesContainPayloads() {
        func clause(_ value: String) -> String {
            SurrealQueryBuilder.whereClause(
                filters: [(column: "c", op: "=", value: value)], logicMode: "and"
            ) ?? ""
        }
        // String branch: the closing quote is escaped.
        #expect(clause("x'; REMOVE TABLE person; --") == "c = 'x\\'; REMOVE TABLE person; --'")
        // Record branch: the id part is backtick-quoted, so ; stays inside the identifier.
        let recordish = clause("person:a;REMOVE")
        #expect(recordish.hasPrefix("c = person:`") && recordish.hasSuffix("`"))
    }

    @Test("Count uses GROUP ALL")
    func count() {
        let query = SurrealQueryBuilder.count(table: "person", scope: scope, filters: [], logicMode: "and")
        #expect(query.contains("SELECT count() AS total FROM person GROUP ALL;"))
    }
}

@Suite("SurrealDB - field kinds across 2.x and 3.x")
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

@Suite("SurrealDB - INFO parsing across 2.x and 3.x")
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

@Suite("SurrealDB - row flattening")
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
        let flattened = SurrealRowFlattener.flatten(rows)
        #expect(flattened.columns == ["id", "n", "other"])
        #expect(flattened.rows.count == 2)
    }

    @Test("Ragged rows leave sparse cells empty, not broken")
    func ragged() {
        let rows = SurrealValue.array([
            .object([(key: "a", value: .int(1))]),
            .object([(key: "b", value: .int(2))]),
        ])
        let flattened = SurrealRowFlattener.flatten(rows)
        #expect(flattened.columns == ["a", "b"])
        #expect(flattened.rows[0][1] == .null)
        #expect(flattened.rows[1][0] == .null)
    }

    @Test("Nested values become compact JSON text")
    func nested() {
        let rows = SurrealValue.array([
            .object([(key: "meta", value: .object([(key: "k", value: .int(1))]))]),
        ])
        let flattened = SurrealRowFlattener.flatten(rows)
        #expect(flattened.rows[0][0] == .text(#"{"k":1}"#))
    }
}

@Suite("SurrealDB - statement generation")
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

    @Test("An update sets only the changed cells and never replaces the record")
    func update() throws {
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 2, columnName: "age", oldValue: .text("30"), newValue: .text("31"))],
            originalRow: [.text("person:alice"), .text("Alice"), .text("30")]
        )
        let statements = SurrealStatementGenerator.statements(
            table: "person", scope: scope, columns: columns, kinds: kinds,
            changes: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )
        let statement = try #require(statements.first)

        #expect(statement.statement.contains("UPDATE $p0 SET age = $p1;"))
        #expect(!statement.statement.contains("CONTENT"))
        #expect(!statement.statement.contains("MERGE"))
        #expect(statement.statement.contains("USE NS ns DB db;"))

        #expect(decoded(statement.parameters[0])
            == .recordId(SurrealRecordID(table: "person", id: .string("alice"))))
        #expect(decoded(statement.parameters[1]) == .int(31), "an int column must bind as an int, not a string")
    }

    @Test("The record id is bound, never interpolated")
    func boundRecordId() throws {
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "name", oldValue: .text("a"), newValue: .text("'; REMOVE TABLE person; --"))],
            originalRow: [.text("person:alice"), .text("a"), .null]
        )
        let statements = SurrealStatementGenerator.statements(
            table: "person", scope: scope, columns: columns, kinds: kinds,
            changes: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )
        let statement = try #require(statements.first)
        #expect(!statement.statement.contains("REMOVE TABLE"))
        #expect(decoded(statement.parameters[1]) == .string("'; REMOVE TABLE person; --"))
    }

    @Test("An insert omits a blank id so the server mints one")
    func insert() throws {
        let statements = SurrealStatementGenerator.statements(
            table: "person", scope: scope, columns: columns, kinds: kinds,
            changes: [], insertedRowData: [0: [.text(""), .text("Carol"), .text("22")]],
            deletedRowIndices: [], insertedRowIndices: [0]
        )
        let statement = try #require(statements.first)
        #expect(statement.statement.contains("CREATE person SET name = $p0, age = $p1;"))
        #expect(decoded(statement.parameters[1]) == .int(22))
    }

    @Test("An insert with an explicit id binds it as a record id")
    func insertWithId() throws {
        let statements = SurrealStatementGenerator.statements(
            table: "person", scope: scope, columns: columns, kinds: kinds,
            changes: [], insertedRowData: [0: [.text("person:carol"), .text("Carol"), .null]],
            deletedRowIndices: [], insertedRowIndices: [0]
        )
        let statement = try #require(statements.first)
        #expect(statement.statement.contains("CREATE $p0 SET name = $p1;"))
        #expect(decoded(statement.parameters[0])
            == .recordId(SurrealRecordID(table: "person", id: .string("carol"))))
    }

    @Test("A delete addresses the record directly")
    func delete() throws {
        let change = PluginRowChange(
            rowIndex: 0, type: .delete, cellChanges: [],
            originalRow: [.text("person:alice"), .text("Alice"), .text("30")]
        )
        let statements = SurrealStatementGenerator.statements(
            table: "person", scope: scope, columns: columns, kinds: kinds,
            changes: [change], insertedRowData: [:], deletedRowIndices: [0], insertedRowIndices: []
        )
        let statement = try #require(statements.first)
        #expect(statement.statement.contains("DELETE $p0;"))
        #expect(statement.parameters.count == 1)
    }

    @Test("The auto-id marker on insert lets the server mint the id")
    func autoDefaultInsertId() throws {
        let statements = SurrealStatementGenerator.statements(
            table: "person", scope: scope, columns: columns, kinds: kinds,
            changes: [], insertedRowData: [0: [.text("__DEFAULT__"), .text("Carol"), .text("22")]],
            deletedRowIndices: [], insertedRowIndices: [0]
        )
        let statement = try #require(statements.first)
        #expect(statement.statement.contains("CREATE person SET"))
        #expect(!statement.statement.contains("__DEFAULT__"))
        #expect(!statement.statement.contains("person:__DEFAULT__"))
    }

    @Test("The auto-id marker on an updated field is skipped, never written literally")
    func autoDefaultUpdateField() {
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "name", oldValue: .text("Alice"), newValue: .text("__DEFAULT__"))],
            originalRow: [.text("person:alice"), .text("Alice"), .text("30")]
        )
        let statements = SurrealStatementGenerator.statements(
            table: "person", scope: scope, columns: columns, kinds: kinds,
            changes: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )
        #expect(statements.isEmpty, "an all-default update produces no statement, not a literal write")
    }

    @Test("The id column is never written")
    func immutableId() {
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 0, columnName: "id", oldValue: .text("person:a"), newValue: .text("person:b"))],
            originalRow: [.text("person:a"), .text("Alice"), .null]
        )
        let statements = SurrealStatementGenerator.statements(
            table: "person", scope: scope, columns: columns, kinds: kinds,
            changes: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )
        #expect(statements.isEmpty)
    }
}

@Suite("SurrealDB - cell coding")
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
        #expect(value("1h30m", "duration") == .duration(seconds: 5400, nanoseconds: 0))
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

@Suite("SurrealDB - connection config")
struct SurrealDBConnectionConfigTests {
    private func config(_ level: String, namespace: String = "ns", extra: [String: String] = [:]) -> SurrealDBConnectionConfig {
        var fields = ["sdbAuthLevel": level]
        fields.merge(extra) { _, new in new }
        return SurrealDBConnectionConfig(config: DriverConnectionConfig(
            host: "localhost", port: 8000, username: "root", password: "secret",
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
