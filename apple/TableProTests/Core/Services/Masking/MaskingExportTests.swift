//
//  MaskingExportTests.swift
//  TableProTests
//
//  File > Export and Export Results hand rows to a format plugin. A masked column must reach no format raw.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class FixedRowsDataSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId = "mysql"
    private let elements: [PluginStreamElement]

    init(_ elements: [PluginStreamElement]) {
        self.elements = elements
    }

    static let customers = FixedRowsDataSource([
        .header(PluginStreamHeader(columns: ["id", "email"], columnTypeNames: ["int", "varchar"])),
        .rows([[.text("1"), .text("jane@example.com")], [.text("2"), .text("john@example.com")]]),
    ])

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let elements = elements
        return AsyncThrowingStream { continuation in
            for element in elements { continuation.yield(element) }
            continuation.finish()
        }
    }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(
            columns: ["email"],
            columnTypeNames: ["varchar"],
            rows: [[.text("jane@example.com")]],
            rowsAffected: 0,
            executionTime: 0
        )
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String { "" }
    func quoteIdentifier(_ identifier: String) -> String { identifier }
    func escapeStringLiteral(_ value: String) -> String { value }
    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { 2 }
}

struct MaskingExportTests {
    private let policy = MaskingPolicy(rules: [MaskingRule(pattern: "*.email")])

    private static func collect(_ stream: AsyncThrowingStream<PluginStreamElement, Error>) async throws -> [PluginRow] {
        var rows: [PluginRow] = []
        for try await element in stream {
            if case .rows(let chunk) = element { rows += chunk }
        }
        return rows
    }

    @Test("File > Export streams a masked column masked, by table and by object")
    func streamedRowsAreMasked() async throws {
        let source = MaskingExportDataSource.wrapping(FixedRowsDataSource.customers, policy: policy)

        let byTable = try await Self.collect(source.streamRows(table: "customers", databaseName: "shop"))
        let object = PluginExportTable(name: "customers", databaseName: "shop", tableType: "table")
        let byObject = try await Self.collect(source.streamRows(for: object))

        for rows in [byTable, byObject] {
            #expect(rows == [[.text("1"), .text("••••")], [.text("2"), .text("••••")]])
        }
    }

    @Test("A query export named after its file matches a table.column rule by column, not by the file name")
    func queryExportIgnoresTheFileName() async throws {
        let usersOnly = MaskingPolicy(rules: [MaskingRule(pattern: "users.email")])
        let source = MaskingExportDataSource.wrapping(FixedRowsDataSource.customers, policy: usersOnly, streamsTables: false)

        let rows = try await Self.collect(source.streamRows(table: "results", databaseName: ""))

        #expect(rows.allSatisfy { $0[1] == .text("••••") })
    }

    @Test("A format's own query comes back masked")
    func executedRowsAreMasked() async throws {
        let source = MaskingExportDataSource.wrapping(FixedRowsDataSource.customers, policy: policy)
        let result = try await source.execute(query: "SELECT email FROM customers")
        #expect(result.rows == [[.text("••••")]])
    }

    @Test("No rule leaves the data source unwrapped")
    func noRuleIsUnwrapped() {
        let base = FixedRowsDataSource.customers
        #expect(MaskingExportDataSource.wrapping(base, policy: .none) === base)
    }

    @Test("Rows that arrive before their header are refused rather than let through")
    func rowsBeforeHeaderAreRefused() async {
        let headless = FixedRowsDataSource([.rows([[.text("jane@example.com")]])])
        let source = MaskingExportDataSource.wrapping(headless, policy: policy)
        await #expect(throws: (any Error).self) {
            _ = try await Self.collect(source.streamRows(table: "customers", databaseName: "shop"))
        }
    }

    @Test("Export Results writes the grid's masked rows and masks a value it loads from the server")
    @MainActor
    func exportResultsMasksLoadedValues() async throws {
        let masks = policy.columnMasks(table: "customers", columns: ["id", "email"], typeNames: [nil, nil])
        let tableRows = TableRows.from(
            queryRows: [[.text("1"), .text("jane@example.com")], [.text("2"), .null]],
            columns: ["id", "email"],
            columnTypes: [.integer(rawType: nil), .text(rawType: nil)],
            unloadedCells: [1: [1: 4_000]],
            masks: masks
        )
        let source = QueryResultExportDataSource(
            tableRows: tableRows,
            databaseType: .mysql,
            driver: nil,
            fillUnloaded: { rows in
                Dictionary(uniqueKeysWithValues: rows.map { ($0.id, [1: PluginCellValue.text("john@example.com")]) })
            }
        )

        let rows = try await Self.collect(source.streamRows(table: "customers", databaseName: ""))

        #expect(rows == [[.text("1"), .text("••••")], [.text("2"), .text("••••")]])
    }
}
