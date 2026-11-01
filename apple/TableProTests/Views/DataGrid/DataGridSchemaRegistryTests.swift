//
//  DataGridSchemaRegistryTests.swift
//  TableProTests
//

import Foundation
import os
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
struct DataGridSchemaRegistryTests {
    private final class Requests: Sendable {
        let ids = OSAllocatedUnfairLock<[String]>(initialState: [])

        var transport: SchemaRegistryClient.Transport {
            { [self] request in
                ids.withLock { $0.append(request.url?.lastPathComponent ?? "") }
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (Data(#"{"message":"not here"}"#.utf8), response)
            }
        }
    }

    private struct Grid {
        let owner: GridTestOwner
        let model: DataGridModel
        let presenter: DataGridCellPresenter
        let requests: Requests
    }

    private static let connection = UUID()

    private static func grid(_ rows: TableRows) -> Grid {
        let requests = Requests()
        let endpoint = SchemaRegistryEndpoint(fields: [SchemaRegistryConnectionField.url: "http://localhost:8081"])
        let cache = SchemaRegistryCache(resolveEndpoint: { _ in endpoint }, transport: requests.transport)
        let owner = GridTestOwner(rows)
        let model = DataGridModel(schemaRegistry: cache)
        model.dataSource = owner
        model.actions = owner
        owner.model = model
        model.reloadRows()
        return Grid(owner: owner, model: model, presenter: DataGridCellPresenter(model: model), requests: requests)
    }

    private static func framed(_ id: UInt8, _ payload: [UInt8] = [0x02]) -> PluginCellValue {
        .bytes(Data([0, 0, 0, 0, id] + payload))
    }

    private static func cachedText(_ grid: Grid, row: Int, column: Int) -> String? {
        guard let id = grid.model.row(at: row)?.id, let box = grid.model.display.cache.box(forID: id),
              column < box.values.count else { return nil }
        return box.values[column]
    }

    private static func fill(_ grid: Grid, rows: Int, columns: Int) {
        for row in 0..<rows {
            for column in 0..<columns {
                _ = DataGridDisplayCacheTests.text(of: grid.model, presenter: grid.presenter, row: row, column: column)
            }
        }
    }

    @Test("Choosing Schema Registry fetches each schema the column's values name, once")
    func formatPrefetches() async throws {
        let grid = Self.grid(TableRows(
            rows: [
                Row(id: .existing(0), values: [Self.framed(1)]),
                Row(id: .existing(1), values: [Self.framed(2)]),
                Row(id: .existing(2), values: [Self.framed(1)]),
                Row(id: .existing(3), values: [.null]),
            ],
            columns: ["value"],
            columnTypes: [.blob(rawType: "BLOB")]
        ))
        let column = try #require(grid.model.columns.column(at: 0))
        grid.model.setDisplayFormat(.schemaRegistry(connectionID: Self.connection), for: column)
        try await waitUntil { grid.requests.ids.withLock { $0.count } == 2 }
        #expect(Set(grid.requests.ids.withLock { $0 }) == ["1", "2"])
    }

    @Test("A text column holding a framed value from an older plugin is read as its UTF-8 bytes")
    func textColumnPrefetches() async throws {
        let grid = Self.grid(TableRows(
            rows: [Row(id: .existing(0), values: [.text("\u{0}\u{0}\u{0}\u{0}\u{9}{\"a\":1}")])],
            columns: ["value"],
            columnTypes: [.text(rawType: nil)]
        ))
        let column = try #require(grid.model.columns.column(at: 0))
        grid.model.setDisplayFormat(.schemaRegistry(connectionID: Self.connection), for: column)
        try await waitUntil { grid.requests.ids.withLock { $0 } == ["9"] }
    }

    @Test("Rows added later fetch only the schemas they name")
    func insertedRowsPrefetch() async throws {
        let grid = Self.grid(TableRows(
            rows: [Row(id: .existing(0), values: [Self.framed(1)])],
            columns: ["value"],
            columnTypes: [.blob(rawType: "BLOB")]
        ))
        let column = try #require(grid.model.columns.column(at: 0))
        grid.model.setDisplayFormat(.schemaRegistry(connectionID: Self.connection), for: column)
        try await waitUntil { grid.requests.ids.withLock { $0 } == ["1"] }

        grid.owner.tableRows.rows.append(Row(id: .existing(1), values: [Self.framed(5)]))
        grid.model.apply(.rowsInserted(IndexSet(integer: 1)))
        try await waitUntil { grid.requests.ids.withLock { $0 } == ["1", "5"] }
    }

    @Test("A registry change redraws only that connection's columns, keeping every other column's text")
    func changeClearsOnlyRegistryColumns() async throws {
        let grid = Self.grid(TableRows(
            rows: [Row(id: .existing(0), values: [Self.framed(1), .text("kept")])],
            columns: ["value", "key"],
            columnTypes: [.blob(rawType: "BLOB"), .text(rawType: nil)]
        ))
        let column = try #require(grid.model.columns.column(at: 0))
        grid.model.setDisplayFormat(.schemaRegistry(connectionID: Self.connection), for: column)
        Self.fill(grid, rows: 1, columns: 2)
        #expect(Self.cachedText(grid, row: 0, column: 0) != nil)

        NotificationCenter.default.post(
            name: SchemaRegistryCache.didChange, object: nil, userInfo: [SchemaRegistryCache.connectionIDKey: UUID()]
        )
        NotificationCenter.default.post(
            name: SchemaRegistryCache.didChange, object: nil, userInfo: [SchemaRegistryCache.connectionIDKey: Self.connection]
        )
        try await waitUntil { Self.cachedText(grid, row: 0, column: 0) == nil }
        #expect(Self.cachedText(grid, row: 0, column: 1) == "kept")
    }

    @Test("Adding back a schema file this Mac had lost redraws the columns that name it")
    func restoredSchemaRedraws() async throws {
        let grid = Self.grid(TableRows(
            rows: [Row(id: .existing(0), values: [.bytes(Data([0x02])), .text("kept")])],
            columns: ["value", "key"],
            columnTypes: [.blob(rawType: "BLOB"), .text(rawType: nil)]
        ))
        let schemaID = String(repeating: "ab", count: 16)
        let column = try #require(grid.model.columns.column(at: 0))
        grid.model.setDisplayFormat(.avro(schemaID: schemaID), for: column)
        Self.fill(grid, rows: 1, columns: 2)
        #expect(Self.cachedText(grid, row: 0, column: 0) != nil)

        NotificationCenter.default.post(
            name: AvroSchemaStore.didRestoreSchema, object: nil, userInfo: [AvroSchemaStore.schemaIDKey: schemaID]
        )
        try await waitUntil { Self.cachedText(grid, row: 0, column: 0) == nil }
        #expect(Self.cachedText(grid, row: 0, column: 1) == "kept")
    }
}
