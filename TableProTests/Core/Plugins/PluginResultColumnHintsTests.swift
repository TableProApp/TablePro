//
//  PluginResultColumnHintsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class ResultStubDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let result: PluginQueryResult

    init(result: PluginQueryResult) {
        self.result = result
    }

    func execute(query: String) async throws -> PluginQueryResult {
        result
    }

    func connect() async throws {}
    func disconnect() {}
    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

@Suite("Result column classification hints")
struct PluginResultColumnHintsTests {
    private func column(_ name: String, declared: String, hint: String?) -> PluginColumnInfo {
        PluginColumnInfo(
            name: name,
            dataType: declared,
            generationExpression: nil,
            generationKind: nil,
            ddlSpelling: nil,
            ddlDefault: nil,
            ddlGenerationExpression: nil,
            ddlCollation: nil,
            classificationTypeName: hint
        )
    }

    private func columnTypes(
        names: [String],
        typeNames: [String],
        meta: [PluginColumnInfo]?,
        type: DatabaseType = .dynamodb
    ) async throws -> [ColumnType] {
        let result = PluginQueryResult(
            columns: names,
            columnTypeNames: typeNames,
            rows: [],
            rowsAffected: 0,
            executionTime: 0,
            columnMeta: meta
        )
        let adapter = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(type: type),
            pluginDriver: ResultStubDriver(result: result)
        )
        return try await adapter.execute(query: "SELECT 1").columnTypes
    }

    @Test("A hinted column is classified by the hint and keeps the name the server declared")
    func hintClassifiesWhileTheDeclaredNameStays() async throws {
        let names = ["pk", "doc", "items", "tags", "total", "active", "payload"]
        let declared = ["String", "Map", "List", "String Set", "Number", "Boolean", "Binary"]
        let hints = ["TEXT", "JSON", "JSON", "JSON", "NUMERIC", "BOOLEAN", "BLOB"]
        let meta = zip(names, zip(declared, hints)).map { column($0, declared: $1.0, hint: $1.1) }

        let types = try await columnTypes(names: names, typeNames: declared, meta: meta)

        #expect(types == [
            .text(rawType: "String"),
            .json(rawType: "Map"),
            .json(rawType: "List"),
            .json(rawType: "String Set"),
            .decimal(rawType: "Number"),
            .boolean(rawType: "Boolean"),
            .blob(rawType: "Binary")
        ])
    }

    @Test("A column without a hint is classified exactly as before")
    func unhintedColumnsKeepTheirClassification() async throws {
        let names = ["id", "name", "doc"]
        let declared = ["INT", "VARCHAR", "Map"]
        let meta = [
            column("id", declared: "INT", hint: nil),
            column("name", declared: "VARCHAR", hint: nil),
            column("doc", declared: "Map", hint: "JSON")
        ]
        let classifier = ColumnTypeClassifier()

        let types = try await columnTypes(names: names, typeNames: declared, meta: meta, type: .mysql)

        #expect(types[0] == classifier.classify(rawTypeName: "INT"))
        #expect(types[1] == classifier.classify(rawTypeName: "VARCHAR"))
        #expect(types[2] == .json(rawType: "Map"))
    }

    @Test("Hints that do not describe every column are ignored, never matched by position")
    func partialHintsAreIgnored() async throws {
        let meta = [column("tags", declared: "String Set", hint: "JSON")]
        let classifier = ColumnTypeClassifier()

        let types = try await columnTypes(
            names: ["pk", "tags"], typeNames: ["String", "String Set"], meta: meta
        )

        #expect(types == [
            classifier.classify(rawTypeName: "String"),
            classifier.classify(rawTypeName: "String Set")
        ])
    }

    @Test("A result with no column metadata is classified by its declared names alone")
    func missingMetadataKeepsDeclaredClassification() async throws {
        let classifier = ColumnTypeClassifier()

        let types = try await columnTypes(names: ["tags"], typeNames: ["String Set"], meta: nil)

        #expect(types == [classifier.classify(rawTypeName: "String Set")])
    }

    @Test("Hints are read one per column, nil where the driver set none")
    func hintsLineUpWithColumns() {
        let meta = [column("a", declared: "Map", hint: "JSON"), column("b", declared: "INT", hint: nil)]

        #expect(PluginResultColumnHints.hints(from: meta, columnCount: 2) == ["JSON", nil])
        #expect(PluginResultColumnHints.hints(from: meta, columnCount: 3) == [nil, nil, nil])
        #expect(PluginResultColumnHints.hints(from: nil, columnCount: 1) == [nil])
    }

    @Test("Declaring a name keeps the kind, an enum's values and an array's element")
    func declaredKeepsTheKind() {
        #expect(ColumnType.json(rawType: "JSON").declared(as: "Map") == .json(rawType: "Map"))
        #expect(
            ColumnType.enumType(rawType: "ENUM", values: ["a"]).declared(as: "mood")
                == .enumType(rawType: "mood", values: ["a"])
        )
        #expect(
            ColumnType.array(rawType: "INT[]", element: .integer(rawType: "INT")).declared(as: "Number Set")
                == .array(rawType: "Number Set", element: .integer(rawType: "INT"))
        )
    }
}
