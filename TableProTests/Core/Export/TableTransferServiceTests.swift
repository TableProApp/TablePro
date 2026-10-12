//
//  TableTransferServiceTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

/// Serves one table's rows as a source, and records what reaches it as a destination.
private final class TransferStubDriver: PluginDatabaseDriver, @unchecked Sendable {
    let header: [String]
    let rows: [PluginRow]
    let columns: [String]
    private(set) var executedQueries: [String] = []
    private(set) var executedParameters: [[PluginCellValue]] = []

    init(header: [String] = [], rows: [PluginRow] = [], columns: [String] = []) {
        self.header = header
        self.rows = rows
        self.columns = columns
    }

    var insertStatements: [String] {
        executedQueries.filter { $0.uppercased().hasPrefix("INSERT") }
    }

    func defaultExportQuery(table: String, schema: String?) -> String? {
        "SELECT * FROM \(table)"
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let header = PluginStreamHeader(
            columns: header, columnTypeNames: header.map { _ in "TEXT" })
        let rows = rows
        return AsyncThrowingStream { continuation in
            continuation.yield(.header(header))
            continuation.yield(.rows(rows))
            continuation.finish()
        }
    }

    func connect() async throws {}
    func disconnect() {}

    func execute(query: String) async throws -> PluginQueryResult {
        executedQueries.append(query)
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        executedQueries.append(query)
        executedParameters.append(parameters)
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        columns.map { PluginColumnInfo(name: $0, dataType: "TEXT") }
    }

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

struct TableTransferServiceTests {
    private func adapter(_ driver: TransferStubDriver, type: DatabaseType) -> PluginDriverAdapter {
        PluginDriverAdapter(connection: DatabaseConnection(name: "Test", type: type), pluginDriver: driver)
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test("A row is keyed by its header's column names, in order")
    func rowIsKeyedByHeader() {
        let values = TableTransferService.dictionary(
            columns: ["id", "name", "email"],
            row: [.text("1"), .text("Ada"), .text("ada@example.com")]
        )
        #expect(values.count == 3)
        #expect(values["id"] == .text("1"))
        #expect(values["name"] == .text("Ada"))
        #expect(values["email"] == .text("ada@example.com"))
    }

    /// A driver that stops sending values once the rest of a row is null would otherwise lose the
    /// whole row: the sink writes by column name, and a missing key is not a null.
    @Test("A row shorter than its header is padded with nulls")
    func shortRowIsPadded() {
        let values = TableTransferService.dictionary(
            columns: ["id", "name", "email"],
            row: [.text("1")]
        )
        #expect(values.count == 3)
        #expect(values["id"] == .text("1"))
        #expect(values["name"] == .null)
        #expect(values["email"] == .null)
    }

    @Test("A row longer than its header keeps only the named columns")
    func extraValuesAreDropped() {
        let values = TableTransferService.dictionary(
            columns: ["id"],
            row: [.text("1"), .text("unnamed")]
        )
        #expect(values == ["id": .text("1")])
    }

    @Test("An empty header produces no values")
    func emptyHeaderProducesNothing() {
        #expect(TableTransferService.dictionary(columns: [], row: [.text("1")]).isEmpty)
    }

    @Test("Binary and null values survive the transfer unchanged")
    func binaryAndNullSurvive() {
        let payload = Data([0x00, 0xFF, 0x10])
        let values = TableTransferService.dictionary(
            columns: ["blob", "missing"],
            row: [.bytes(payload), .null]
        )
        #expect(values["blob"] == .bytes(payload))
        #expect(values["missing"] == .null)
    }

    /// The transfer moves rows, so a request naming only definition objects has nothing to do and
    /// must say so rather than reporting a successful transfer of nothing.
    @MainActor @Test("A request with no row-carrying object is refused")
    func requestWithoutTablesIsRefused() {
        let service = TableTransferService()
        let request = TableTransferService.Request(
            objects: [
                ExportObjectItem(name: "recalc", kind: .routine),
                ExportObjectItem(name: "audit", kind: .trigger, parentTable: "users")
            ],
            sourceType: .postgresql,
            destinationType: .postgresql
        )
        #expect(request.objects.allSatisfy { !$0.kind.carriesRows })
        #expect(service.state.isTransferring == false)
    }

    @Test("A request keeps the row scope of every object it names")
    func requestKeepsRowScope() {
        let scoped = ExportObjectItem(
            name: "users",
            kind: .table,
            isSelected: true,
            rowScope: PluginExportRowScope(filter: "active", rowLimit: 10)
        )
        let request = TableTransferService.Request(
            objects: [scoped], sourceType: .mysql, destinationType: .postgresql)
        #expect(request.objects[0].rowScope.sanitizedFilter == "active")
        #expect(request.objects[0].rowScope.rowLimit == 10)
    }

    @Test("Transactions and row deletion default to the safe choice")
    func requestDefaults() {
        let request = TableTransferService.Request(
            objects: [], sourceType: .mysql, destinationType: .mysql)
        #expect(request.wrapInTransaction)
        #expect(!request.deleteExistingRows)
    }

    @Test("A mapping that sends two source columns to one destination column is refused")
    func contestedMappingIsRefused() {
        let objects = [ExportObjectItem(name: "people", kind: .table)]
        #expect(throws: TableTransferError.self) {
            try TableTransferService.refuseContestedMappings(
                ["people": ["first_name": "name", "last_name": "name"]], for: objects)
        }
        #expect(throws: Never.self) {
            try TableTransferService.refuseContestedMappings(
                ["people": ["first_name": "first_name", "last_name": "last_name"]], for: objects)
        }
    }

    /// The server refused the INSERT only after "Delete existing rows first" had run, and with no
    /// transaction around the table the deletion stood: the destination was left empty.
    @MainActor @Test("A contested mapping deletes nothing on the destination")
    func contestedMappingDeletesNothing() async {
        let source = TransferStubDriver(header: ["first_name", "last_name"], rows: [[.text("Ada"), .text("Lovelace")]])
        let destination = TransferStubDriver(columns: ["name"])
        let request = TableTransferService.Request(
            objects: [ExportObjectItem(name: "people", kind: .table, isSelected: true)],
            sourceType: .postgresql,
            destinationType: .mysql,
            columnMapping: ["people": ["first_name": "name", "last_name": "name"]],
            deleteExistingRows: true,
            wrapInTransaction: false
        )

        do {
            try await TableTransferService().transfer(
                request: request,
                sourceDriver: adapter(source, type: .postgresql),
                destinationDriver: adapter(destination, type: .mysql)
            )
            Issue.record("A mapping naming one destination column twice was transferred")
        } catch TableTransferError.contestedDestination(let table, let columns) {
            #expect(table == "people")
            #expect(columns == ["name"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(destination.executedQueries.isEmpty)
    }

    /// `Name` and `name` both matched a lone `name`, and even with only one of them mapped the
    /// sink folded the other onto it, so the INSERT named the column twice.
    @MainActor @Test("A source column that differs only by case from a mapped one is not written twice")
    func caseTwinIsNotWrittenTwice() async throws {
        let source = TransferStubDriver(
            header: ["id", "Name", "name"], rows: [[.text("1"), .text("Display"), .text("login")]])
        let destination = TransferStubDriver(columns: ["id", "name"])
        let request = TableTransferService.Request(
            objects: [ExportObjectItem(name: "people", kind: .table, isSelected: true)],
            sourceType: .postgresql,
            destinationType: .mysql,
            sourceColumns: ["people": ["id", "Name", "name"]],
            deleteExistingRows: true,
            wrapInTransaction: false
        )

        let service = TableTransferService()
        try await service.transfer(
            request: request,
            sourceDriver: adapter(source, type: .postgresql),
            destinationDriver: adapter(destination, type: .mysql)
        )

        let insert = try #require(destination.insertStatements.first)
        #expect(destination.insertStatements.count == 1)
        #expect(occurrences(of: "`name`", in: insert) == 1)
        #expect(destination.executedParameters.last?.contains(.text("login")) == true)
        #expect(destination.executedParameters.last?.contains(.text("Display")) == false)
        #expect(service.state.transferredRows == 1)
        #expect(service.state.warnings.contains { $0.contains("Name") })
    }

    @MainActor @Test("Twins mapped by the user to their own columns each reach their own column")
    func mappedTwinsReachTheirOwnColumns() async throws {
        let source = TransferStubDriver(
            header: ["Name", "name"], rows: [[.text("Display"), .text("login")]])
        let destination = TransferStubDriver(columns: ["display_name", "login"])
        let request = TableTransferService.Request(
            objects: [ExportObjectItem(name: "people", kind: .table, isSelected: true)],
            sourceType: .postgresql,
            destinationType: .mysql,
            columnMapping: ["people": ["Name": "display_name", "name": "login"]]
        )

        try await TableTransferService().transfer(
            request: request,
            sourceDriver: adapter(source, type: .postgresql),
            destinationDriver: adapter(destination, type: .mysql)
        )

        let insert = try #require(destination.insertStatements.first)
        #expect(occurrences(of: "`display_name`", in: insert) == 1)
        #expect(occurrences(of: "`login`", in: insert) == 1)
    }
}
