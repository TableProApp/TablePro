//
//  ImportDataSinkAdapterParameterTypeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private struct SentStatement {
    let sql: String
    let typeNames: [String?]?
}

private struct CatalogRefused: Error {}

private final class TypedTableDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [SentStatement] = []
    private let refusesCatalog: Bool

    init(refusesCatalog: Bool = false) {
        self.refusesCatalog = refusesCatalog
    }

    var statements: [SentStatement] { lock.withLock { sent } }

    func quoteIdentifier(_ name: String) -> String { "\"\(name)\"" }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        if refusesCatalog { throw CatalogRefused() }
        return [
            PluginColumnInfo(name: "ID", dataType: "NUMBER(10)", isNullable: false, isPrimaryKey: true),
            PluginColumnInfo(name: "CODE", dataType: "VARCHAR2(20 BYTE)")
        ]
    }

    func executeParameterized(
        query: String,
        parameters: [PluginCellValue],
        context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        lock.withLock { sent.append(SentStatement(sql: query, typeNames: context.parameterTypeNames)) }
        guard query.hasPrefix("SELECT") else { return .empty }
        return PluginQueryResult(
            columns: ["position", "count"], columnTypeNames: [], rows: [[.text("0"), .text("1")]],
            rowsAffected: 0, executionTime: 0
        )
    }
}

// Oracle stored an imported `00123` in a VARCHAR2 as 123: the driver was never told the column was text.
struct ImportDataSinkAdapterParameterTypeTests {
    private static let mapping = ["ID": "ID", "CODE": "CODE"]

    private func sink(on driver: TypedTableDriver, rowWriting: ImportRowWriting = .insert) -> ImportDataSinkAdapter {
        ImportDataSinkAdapter(
            driver: PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .postgresql), pluginDriver: driver),
            databaseType: .postgresql,
            targetTable: "PEOPLE",
            columnMapping: Self.mapping,
            sourceFields: Set(Self.mapping.keys),
            rowWriting: rowWriting
        )
    }

    @Test
    func importedRowsTellTheDriverEachValuesColumnType() async throws {
        let driver = TypedTableDriver()

        try await sink(on: driver).insertRows([["ID": .text("1"), "CODE": .text("00123")]])

        let insert = try #require(driver.statements.first)
        #expect(insert.sql.hasPrefix("INSERT INTO \"PEOPLE\" (\"CODE\", \"ID\")"))
        #expect(insert.typeNames == ["VARCHAR2(20 BYTE)", "NUMBER(10)"])
    }

    @Test
    func aSingleRowAndOrderedRowsTellTheDriverTheTypesToo() async throws {
        let driver = TypedTableDriver()
        let target = sink(on: driver)

        try await target.insertRow(["ID": .text("1"), "CODE": .text("00123")])
        try await target.insertRows(columns: ["ID", "CODE"], values: [[.text("2"), .text("00456")]])

        let typeNames = driver.statements.map { $0.typeNames }
        #expect(typeNames == [
            ["VARCHAR2(20 BYTE)", "NUMBER(10)"],
            ["NUMBER(10)", "VARCHAR2(20 BYTE)"]
        ])
    }

    @Test
    func matchingTellsTheDriverTheKeyAndAssignmentTypes() async throws {
        let driver = TypedTableDriver()
        let target = sink(on: driver, rowWriting: ImportRowWriting(mode: .update, keyColumns: ["ID"]))

        try await target.insertRows([["ID": .text("7"), "CODE": .text("00123")]])

        let match = try #require(driver.statements.first)
        let update = try #require(driver.statements.last)
        #expect(match.sql.hasPrefix("SELECT 0, COUNT(*)"))
        #expect(match.typeNames == ["NUMBER(10)"])
        #expect(update.sql.hasPrefix("UPDATE \"PEOPLE\" SET \"CODE\""))
        #expect(update.typeNames == ["VARCHAR2(20 BYTE)", "NUMBER(10)"])
    }

    @Test
    func aTargetWhoseColumnsCannotBeReadStillImportsUntyped() async throws {
        let driver = TypedTableDriver(refusesCatalog: true)

        try await sink(on: driver).insertRows([["ID": .text("1"), "CODE": .text("00123")]])

        let insert = try #require(driver.statements.first)
        #expect(insert.sql.hasPrefix("INSERT INTO \"PEOPLE\""))
        #expect(insert.typeNames == nil)
    }
}
