//
//  MaskingExportTests.swift
//  TableProTests
//
//  File > Export and Export Results hand rows to a format plugin. A masked column must reach no format raw.
//

import Foundation
import os
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

    @Test("A masked stream reads a row batch only when its consumer asks for one")
    func maskedStreamPullsOnDemand() async throws {
        let pulls = OSAllocatedUnfairLock(initialState: 0)
        let endless = AsyncThrowingStream<PluginStreamElement, Error>(unfolding: {
            let pull = pulls.withLock { count -> Int in
                count += 1
                return count
            }
            return pull == 1
                ? .header(PluginStreamHeader(columns: ["id", "email"], columnTypeNames: ["INT", "VARCHAR"]))
                : .rows([[.text("1"), .text("a@example.com")]])
        })
        var iterator = MaskingExportDataSource.masking(endless, table: "customers", policy: policy).makeAsyncIterator()
        _ = try await iterator.next()
        let batch = try await iterator.next()
        guard case .rows(let rows)? = batch else {
            Issue.record("expected rows")
            return
        }
        #expect(rows == [[.text("1"), .text("••••")]])
        // A pump would have run ahead of a consumer that stopped here.
        try await Task.sleep(for: .milliseconds(50))
        #expect(pulls.withLock { $0 } == 2)
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

    @Test("Export Results loads each chunk of server values during the writer's pull for it")
    @MainActor
    func exportResultsLoadsValuesAsTheWriterPulls() async throws {
        let count = 120
        let tableRows = TableRows.from(
            queryRows: (0..<count).map { [.text(String($0)), .null] },
            columns: ["id", "email"],
            columnTypes: [.integer(rawType: nil), .text(rawType: nil)],
            unloadedCells: Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, [1: 4_000]) })
        )
        let pulls = OSAllocatedUnfairLock(initialState: 0)
        let pullsAtEachFill = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let source = QueryResultExportDataSource(
            tableRows: tableRows,
            databaseType: .mysql,
            driver: nil,
            fillUnloaded: { rows in
                let pull = pulls.withLock { $0 }
                pullsAtEachFill.withLock { $0.append(pull) }
                return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, [1: PluginCellValue.text("x")]) })
            }
        )
        let stream = source.streamExportRows(table: "customers", databaseName: "")

        // Off the main actor, so a fill that ran ahead of the writer would not wait behind it.
        try await Task.detached {
            var iterator = stream.makeAsyncIterator()
            while true {
                pulls.withLock { $0 += 1 }
                guard try await iterator.next() != nil else { break }
            }
        }.value

        // Pull 1 is the header; the three chunks of 50, 50 and 20 rows are filled during pulls 2, 3 and 4.
        #expect(pullsAtEachFill.withLock { $0 } == [2, 3, 4])
    }
}
