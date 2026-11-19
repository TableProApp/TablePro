//
//  DataDictionaryGroupReadTests.swift
//  FormatPluginTests
//

import Foundation
import TableProPluginKit
import Testing

private struct Denied: LocalizedError {
    var errorDescription: String? { "permission denied" }
}

private final class GroupReadingSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId = "PostgreSQL"
    let bulkReads: PluginExportBulkReads
    var failsBulkColumns = false
    private(set) var calls: [String] = []

    private let columns: [String: [PluginColumnInfo]] = [
        "orgs": [PluginColumnInfo(name: "id", dataType: "integer", isNullable: false, isPrimaryKey: true)],
        "users": [
            PluginColumnInfo(name: "id", dataType: "bigint", isNullable: false, isPrimaryKey: true),
            PluginColumnInfo(name: "org_id", dataType: "integer", isNullable: true, comment: "Owner")
        ],
    ]
    private let indexes: [String: [PluginIndexInfo]] = [
        "users": [PluginIndexInfo(name: "users_org_idx", columns: ["org_id"], type: "btree")]
    ]
    private let foreignKeys: [String: [PluginForeignKeyInfo]] = [
        "users": [PluginForeignKeyInfo(
            name: "users_org_fk", column: "org_id", referencedTable: "orgs", referencedColumn: "id",
            referencedDatabase: nil, referencedSchema: "public", onDelete: "CASCADE"
        )]
    ]

    init(bulkReads: PluginExportBulkReads) {
        self.bulkReads = bulkReads
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String { "" }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func quoteIdentifier(_ identifier: String) -> String { "\"\(identifier)\"" }
    func escapeStringLiteral(_ value: String) -> String { value }
    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }

    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo] {
        calls.append("columns \(table)")
        return columns[table] ?? []
    }

    func fetchAllColumns(databaseName: String) async throws -> [String: [PluginColumnInfo]] {
        calls.append("all columns")
        if failsBulkColumns { throw Denied() }
        return columns
    }

    func fetchIndexes(table: String, databaseName: String) async throws -> [PluginIndexInfo] {
        calls.append("indexes \(table)")
        return indexes[table] ?? []
    }

    func fetchAllIndexes(databaseName: String) async throws -> [String: [PluginIndexInfo]] {
        calls.append("all indexes")
        return indexes
    }

    func fetchForeignKeys(table: String, databaseName: String) async throws -> [PluginForeignKeyInfo] {
        calls.append("foreign keys \(table)")
        return foreignKeys[table] ?? []
    }

    func fetchAllForeignKeys(databaseName: String) async throws -> [String: [PluginForeignKeyInfo]] {
        calls.append("all foreign keys")
        return foreignKeys
    }
}

struct DataDictionaryGroupReadTests {
    private static let tables = ["orgs", "users"].map {
        PluginExportTable(name: $0, databaseName: "public", tableType: "table", schema: "public", kind: .table)
    }

    private func export(_ tables: [PluginExportTable], from source: GroupReadingSource) async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("shop.md")
        let plugin = DataDictionaryExportPlugin()
        let original = plugin.settings
        defer { plugin.settings = original }
        plugin.settings.fileType = .markdown
        _ = try await plugin.export(
            tables: tables,
            dataSource: source,
            destination: destination,
            progress: PluginExportProgress(progress: Progress(totalUnitCount: 0))
        )
        let text = try String(contentsOf: destination, encoding: .utf8)
        return text.components(separatedBy: "\n").filter { !$0.contains("generated") }.joined(separator: "\n")
    }

    @Test("A group whose source reads it whole is asked once per kind, and the file reads as it did table by table")
    func groupReadMatchesTableReads() async throws {
        let grouped = GroupReadingSource(bulkReads: [.columns, .foreignKeys, .indexes])
        let alone = GroupReadingSource(bulkReads: [])

        let groupedText = try await export(Self.tables, from: grouped)
        let aloneText = try await export(Self.tables, from: alone)

        #expect(grouped.calls == ["all columns", "all indexes", "all foreign keys"])
        #expect(alone.calls == [
            "columns orgs", "indexes orgs", "foreign keys orgs", "columns users", "indexes users", "foreign keys users",
        ])
        #expect(groupedText == aloneText)
    }

    @Test("A group read that fails falls back to each table's own read")
    func failedGroupReadFallsBack() async throws {
        let source = GroupReadingSource(bulkReads: [.columns, .foreignKeys, .indexes])
        source.failsBulkColumns = true

        _ = try await export(Self.tables, from: source)

        #expect(source.calls == ["all columns", "all indexes", "all foreign keys", "columns orgs", "columns users"])
    }

    @Test("A group read that reached the row limit is set aside, since it may have stopped inside a table")
    func groupReadAtTheRowLimitFallsBack() async throws {
        let source = GroupReadingSource(bulkReads: [.columns, .foreignKeys, .indexes])

        let reads = try await DataDictionaryGroupReads.read(
            databaseName: "public",
            objectCount: 2,
            from: source,
            progress: PluginExportProgress(progress: Progress(totalUnitCount: 0)),
            rowLimit: 3
        )

        #expect(reads.columns == nil)
        #expect(reads.indexes?.isEmpty == false)
        #expect(reads.foreignKeys?.isEmpty == false)
    }

    @Test("A group of one object is read on its own")
    func singleObjectReadsAlone() async throws {
        let source = GroupReadingSource(bulkReads: [.columns, .foreignKeys, .indexes])

        _ = try await export([Self.tables[0]], from: source)

        #expect(source.calls == ["columns orgs", "indexes orgs", "foreign keys orgs"])
    }
}
