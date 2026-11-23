//
//  TableTransferDestinationSchemaTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class SchemaTransferStubDriver: PluginDriverStub, @unchecked Sendable {
    let header: [String]
    let rows: [PluginRow]
    let columns: [String]
    private(set) var executedQueries: [String] = []
    private(set) var columnReadSchemas: [String?] = []

    init(header: [String] = [], rows: [PluginRow] = [], columns: [String] = []) {
        self.header = header
        self.rows = rows
        self.columns = columns
    }

    func quoteIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    func defaultExportQuery(table: String, schema: String?) -> String? {
        "SELECT * FROM \(table)"
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let header = PluginStreamHeader(columns: header, columnTypeNames: header.map { _ in "TEXT" })
        let rows = rows
        return AsyncThrowingStream { continuation in
            continuation.yield(.header(header))
            continuation.yield(.rows(rows))
            continuation.finish()
        }
    }

    func execute(query: String) async throws -> PluginQueryResult {
        executedQueries.append(query)
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        executedQueries.append(query)
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 1, executionTime: 0)
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        columnReadSchemas.append(schema)
        return columns.map { PluginColumnInfo(name: $0, dataType: "TEXT") }
    }
}

// The destination had `sales.orders` and an older `public.orders`. With no schema the DELETE and the INSERTs resolved
// through the session's search_path, emptied and refilled `public.orders`, and left `sales.orders` untouched.
struct TableTransferDestinationSchemaTests {
    private func adapter(_ driver: SchemaTransferStubDriver, type: DatabaseType) -> PluginDriverAdapter {
        PluginDriverAdapter(connection: DatabaseConnection(name: "Test", type: type), pluginDriver: driver)
    }

    @MainActor @Test
    func theDeleteAndTheInsertsNameTheDestinationSchema() async throws {
        let source = SchemaTransferStubDriver(
            header: ["id", "total"], rows: [[.text("1"), .text("9.50")]], columns: ["id", "total"]
        )
        let destination = SchemaTransferStubDriver(columns: ["id", "total"])
        let request = TableTransferService.Request(
            objects: [ExportObjectItem(name: "orders", kind: .table, isSelected: true)],
            sourceType: .mysql,
            destinationType: .postgresql,
            destinationSchema: "sales",
            sourceColumns: ["orders": ["id", "total"]],
            deleteExistingRows: true,
            wrapInTransaction: false
        )

        try await TableTransferService().transfer(
            request: request,
            sourceDriver: adapter(source, type: .mysql),
            destinationDriver: adapter(destination, type: .postgresql)
        )

        let writes = destination.executedQueries.filter { $0.contains("orders") }
        #expect(writes.contains { $0.uppercased().hasPrefix("DELETE") || $0.uppercased().hasPrefix("TRUNCATE") })
        #expect(writes.contains { $0.uppercased().hasPrefix("INSERT") })
        #expect(writes.allSatisfy { $0.contains("\"sales\".\"orders\"") })
        #expect(destination.columnReadSchemas.allSatisfy { $0 == "sales" })
    }

    @Test
    func theSourcesSchemaIsTheDefaultWhenTheDestinationHasIt() {
        let pick = TableTransferSheet.defaultDestinationSchema(
            source: "sales", current: "public", engineDefault: "public", available: ["public", "sales"]
        )
        #expect(pick == "sales")
    }

    @Test
    func theDestinationsOwnSchemaIsTheDefaultOtherwise() {
        #expect(TableTransferSheet.defaultDestinationSchema(
            source: "dbo", current: "reporting", engineDefault: "public", available: ["public", "reporting"]
        ) == "reporting")
        #expect(TableTransferSheet.defaultDestinationSchema(
            source: nil, current: nil, engineDefault: "public", available: ["audit", "public"]
        ) == "public")
        #expect(TableTransferSheet.defaultDestinationSchema(
            source: nil, current: nil, engineDefault: "dbo", available: ["audit"]
        ) == "audit")
        #expect(TableTransferSheet.defaultDestinationSchema(
            source: "sales", current: nil, engineDefault: nil, available: []
        ).isEmpty)
    }
}
