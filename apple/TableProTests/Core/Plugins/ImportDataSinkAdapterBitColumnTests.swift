//
//  ImportDataSinkAdapterBitColumnTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private struct WrittenStatement {
    let sql: String
    let parameters: [PluginCellValue]
}

private final class BitTableDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var written: [WrittenStatement] = []
    private var fetches = 0

    var statements: [WrittenStatement] { lock.withLock { written } }
    var columnFetches: Int { lock.withLock { fetches } }

    func quoteIdentifier(_ name: String) -> String { "`\(name)`" }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        lock.withLock { fetches += 1 }
        return [
            PluginColumnInfo(name: "id", dataType: "int", isNullable: false, isPrimaryKey: true),
            PluginColumnInfo(name: "flags", dataType: "bit(8)"),
            PluginColumnInfo(name: "name", dataType: "varchar(20)")
        ]
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        lock.withLock { written.append(WrittenStatement(sql: query, parameters: parameters)) }
        guard query.hasPrefix("SELECT") else { return .empty }
        return PluginQueryResult(
            columns: ["position", "count"], columnTypeNames: [], rows: [[.text("0"), .text("1")]],
            rowsAffected: 0, executionTime: 0
        )
    }
}

// MySQL stores text bound to a BIT column as its bytes, so an imported 5 read back as 53.
struct ImportDataSinkAdapterBitColumnTests {
    private static let mapping = ["id": "id", "flags": "flags", "name": "name"]

    private func sink(
        on driver: BitTableDriver,
        type: DatabaseType = .mysql,
        rowWriting: ImportRowWriting = .insert
    ) -> ImportDataSinkAdapter {
        ImportDataSinkAdapter(
            driver: PluginDriverAdapter(connection: TestFixtures.makeConnection(type: type), pluginDriver: driver),
            databaseType: type,
            targetTable: "devices",
            columnMapping: Self.mapping,
            sourceFields: Set(Self.mapping.keys),
            rowWriting: rowWriting
        )
    }

    @Test
    func anImportedBitValueIsWrittenAsTheNumber() async throws {
        let driver = BitTableDriver()

        try await sink(on: driver).insertRows([["id": .text("1"), "flags": .text("5"), "name": .text("a")]])

        let insert = try #require(driver.statements.first)
        let parameters = insert.parameters.map { $0.sortKey }
        #expect(insert.sql == "INSERT INTO `devices` (`flags`, `id`, `name`) VALUES (CAST(? AS UNSIGNED), ?, ?)")
        #expect(parameters == ["5", "1", "a"])
    }

    @Test
    func aSingleRowAndOrderedRowsGetTheSameBinding() async throws {
        let driver = BitTableDriver()
        let target = sink(on: driver)

        try await target.insertRow(["id": .text("1"), "flags": .text("5")])
        try await target.insertRows(columns: ["id", "flags"], values: [[.text("2"), .text("6")]])

        let sql = driver.statements.map { $0.sql }
        #expect(sql == [
            "INSERT INTO `devices` (`flags`, `id`) VALUES (CAST(? AS UNSIGNED), ?)",
            "INSERT INTO `devices` (`id`, `flags`) VALUES (?, CAST(? AS UNSIGNED))"
        ])
        #expect(driver.columnFetches == 1)
    }

    @Test
    func matchingOnABitKeyComparesTheNumber() async throws {
        let driver = BitTableDriver()
        let target = sink(on: driver, rowWriting: ImportRowWriting(mode: .update, keyColumns: ["flags"]))

        try await target.insertRows([["flags": .text("5"), "name": .text("b")]])

        let sql = driver.statements.map { $0.sql }
        #expect(sql.first == "SELECT 0, COUNT(*) FROM `devices` WHERE `flags` = CAST(? AS UNSIGNED)")
        #expect(sql.last == "UPDATE `devices` SET `name` = ? WHERE `flags` = CAST(? AS UNSIGNED)")
    }

    // Every engine is asked once, for the column types its driver writes each value by.
    @Test
    func anEngineThatReadsBitsAsDigitsGetsNoCast() async throws {
        let driver = BitTableDriver()

        try await sink(on: driver, type: .postgresql).insertRows([["id": .text("1"), "flags": .text("101")]])

        #expect(driver.columnFetches == 1)
        #expect(driver.statements.first?.sql.contains("CAST") == false)
    }
}
