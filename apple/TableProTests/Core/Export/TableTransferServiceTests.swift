//
//  TableTransferServiceTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class TransferStubDriver: PluginDriverStub, @unchecked Sendable {
    let header: [String]
    let rows: [PluginRow]
    let columns: [String]
    let types: [String: String]
    // What the stream header names a column, where the driver's header and its catalog disagree.
    let headerTypes: [String: String]
    private(set) var executedQueries: [String] = []
    private(set) var executedParameters: [[PluginCellValue]] = []
    private let eventLock = NSLock()
    private var recordedEvents: [String] = []
    var onFetchColumns: (@Sendable () async -> Void)?

    // `stream` when a row stream opens, `columns` when the catalog is read: a real source serves one at a time.
    var events: [String] { eventLock.withLock { recordedEvents } }

    init(
        header: [String] = [],
        rows: [PluginRow] = [],
        columns: [String] = [],
        types: [String: String] = [:],
        headerTypes: [String: String] = [:]
    ) {
        self.header = header
        self.rows = rows
        self.columns = columns
        self.types = types
        self.headerTypes = headerTypes
    }

    var insertStatements: [String] {
        executedQueries.filter { $0.uppercased().hasPrefix("INSERT") }
    }

    // Every destination here is MySQL, whose driver quotes with backticks.
    func quoteIdentifier(_ name: String) -> String {
        "`\(name.replacingOccurrences(of: "`", with: "``"))`"
    }

    func defaultExportQuery(table: String, schema: String?) -> String? {
        "SELECT * FROM \(table)"
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        eventLock.withLock { recordedEvents.append("stream") }
        let header = PluginStreamHeader(
            columns: header, columnTypeNames: header.map { headerTypes[$0] ?? types[$0] ?? "TEXT" })
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
        executedParameters.append(parameters)
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        eventLock.withLock { recordedEvents.append("columns") }
        await onFetchColumns?()
        return columns.map { PluginColumnInfo(name: $0, dataType: types[$0] ?? "TEXT") }
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

    // A driver can stop sending values once the rest of a row is null, and the sink writes by column name: a missing key is not a null.
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

    // Refused rather than reported as a successful transfer of nothing.
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

    // The server refused the INSERT after "Delete existing rows first" ran outside a transaction, which left the destination empty.
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

    // `Name` and `name` both matched a lone `name`, and the sink folded the unmapped one onto it, so the INSERT named the column twice.
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

    // PostgreSQL reads a bit string as its digits; bound to a MySQL BIT as a number, 00000101 would store 101. A fresh
    // session's stream header names the bit column `unknown`, so only the catalog says what it is.
    @MainActor @Test("A PostgreSQL bit string transferred to a MySQL BIT arrives as its number")
    func postgresBitReachesMySQLAsItsNumber() async throws {
        let source = TransferStubDriver(
            header: ["id", "flags"],
            rows: [[.text("1"), .text("00000101")]],
            columns: ["id", "flags"],
            types: ["id": "integer", "flags": "bit(8)"],
            headerTypes: ["id": "integer", "flags": "unknown"]
        )
        let destination = TransferStubDriver(columns: ["id", "flags"], types: ["id": "int", "flags": "bit(8)"])
        let request = TableTransferService.Request(
            objects: [ExportObjectItem(name: "devices", kind: .table, isSelected: true)],
            sourceType: .postgresql,
            destinationType: .mysql,
            sourceColumns: ["devices": ["id", "flags"]],
            wrapInTransaction: false
        )

        try await TableTransferService().transfer(
            request: request,
            sourceDriver: adapter(source, type: .postgresql),
            destinationDriver: adapter(destination, type: .mysql)
        )

        let insert = try #require(destination.insertStatements.first)
        #expect(insert.hasSuffix("VALUES (CAST(? AS UNSIGNED), ?)"))
        #expect(destination.executedParameters.last == [.text("5"), .text("1")])
        // Behind its own open stream, a real source answers the catalog only after the whole table, or never.
        #expect(source.events == ["columns", "stream"])
    }

    @MainActor @Test("A Stop during the catalog reads leaves the destination's rows alone")
    func stopDuringCatalogReadsDeletesNothing() async {
        let source = TransferStubDriver(
            header: ["id", "flags"],
            rows: [[.text("1"), .text("00000101")]],
            columns: ["id", "flags"],
            types: ["id": "integer", "flags": "bit(8)"]
        )
        let destination = TransferStubDriver(columns: ["id", "flags"], types: ["id": "int", "flags": "bit(8)"])
        let service = TableTransferService()
        source.onFetchColumns = { await MainActor.run { service.cancel() } }
        let request = TableTransferService.Request(
            objects: [ExportObjectItem(name: "devices", kind: .table, isSelected: true)],
            sourceType: .postgresql,
            destinationType: .mysql,
            sourceColumns: ["devices": ["id", "flags"]],
            deleteExistingRows: true,
            wrapInTransaction: false
        )

        _ = try? await service.transfer(
            request: request,
            sourceDriver: adapter(source, type: .postgresql),
            destinationDriver: adapter(destination, type: .mysql)
        )

        #expect(source.events == ["columns"])
        #expect(destination.executedQueries.allSatisfy { query in
            !query.uppercased().hasPrefix("DELETE") && !query.uppercased().hasPrefix("TRUNCATE")
        })
        #expect(destination.insertStatements.isEmpty)
    }

    @MainActor @Test("A transfer whose engines cannot both hold a bit string never reads the source catalog")
    func noBitStringsNoSourceCatalogRead() async throws {
        let source = TransferStubDriver(
            header: ["id", "flags"],
            rows: [[.text("1"), .text("5")]],
            columns: ["id", "flags"],
            types: ["id": "INTEGER", "flags": "BIT"]
        )
        let destination = TransferStubDriver(columns: ["id", "flags"], types: ["id": "int", "flags": "bit(8)"])
        let request = TableTransferService.Request(
            objects: [ExportObjectItem(name: "devices", kind: .table, isSelected: true)],
            sourceType: .sqlite,
            destinationType: .mysql,
            sourceColumns: ["devices": ["id", "flags"]],
            wrapInTransaction: false
        )

        try await TableTransferService().transfer(
            request: request,
            sourceDriver: adapter(source, type: .sqlite),
            destinationDriver: adapter(destination, type: .mysql)
        )

        #expect(source.events == ["stream"])
        #expect(destination.executedParameters.last == [.text("5"), .text("1")])
    }

    // The digits take the catalog's BIT(8), whatever width the header names.
    @MainActor @Test("A MySQL BIT transferred to a PostgreSQL bit varying arrives as its digits, at the source's width")
    func mysqlBitReachesPostgresAsItsDigits() async throws {
        let source = TransferStubDriver(
            header: ["id", "flags"],
            rows: [[.text("1"), .text("5")]],
            columns: ["id", "flags"],
            types: ["id": "int", "flags": "bit(8)"],
            headerTypes: ["id": "INT", "flags": "BIT"]
        )
        let destination = TransferStubDriver(columns: ["id", "flags"], types: ["id": "integer", "flags": "varbit"])
        let request = TableTransferService.Request(
            objects: [ExportObjectItem(name: "devices", kind: .table, isSelected: true)],
            sourceType: .mysql,
            destinationType: .postgresql,
            sourceColumns: ["devices": ["id", "flags"]],
            wrapInTransaction: false
        )

        try await TableTransferService().transfer(
            request: request,
            sourceDriver: adapter(source, type: .mysql),
            destinationDriver: adapter(destination, type: .postgresql)
        )

        #expect(destination.executedParameters.last == [.text("00000101"), .text("1")])
        #expect(source.events == ["columns", "stream"])
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
