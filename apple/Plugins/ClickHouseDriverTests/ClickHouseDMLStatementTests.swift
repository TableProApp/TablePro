//
//  ClickHouseDMLStatementTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

/// ClickHouse mutates through `ALTER TABLE … UPDATE` and `ALTER TABLE … DELETE WHERE` rather than
/// the plain `UPDATE` and `DELETE FROM` every other engine takes.
///
/// That shape belongs to the driver: `ClickHousePluginDriver.generateStatements` is the only thing in
/// repository that writes it, and the app's `SQLStatementGenerator` always emits the plain form.
/// Three cases used to assert the ClickHouse shape through `DataChangeManager` with no driver
/// connected, which the app layer cannot produce and never could, so they sat in the quarantine
/// file. Asserted here against the driver, they hold.
struct ClickHouseDMLStatementTests {
    private let table = "users"
    private let columns = ["id", "name"]

    /// The driver, not the plugin: `generateStatements` belongs to `ClickHousePluginDriver`. It is
    /// pure SQL shaping with no connection behind it, so a config that never dials anywhere is
    /// enough to exercise it.
    private var driver: ClickHousePluginDriver {
        ClickHousePluginDriver(config: DriverConnectionConfig(
            host: "localhost",
            port: 8_123,
            username: "default",
            password: "",
            database: "default",
            ssl: SSLConfiguration(),
            additionalFields: [:]
        ))
    }

    private func change(
        _ type: PluginRowChange.ChangeType,
        cells: [(columnIndex: Int, columnName: String, oldValue: PluginCellValue, newValue: PluginCellValue)] = [],
        originalRow: [PluginCellValue]? = nil
    ) -> PluginRowChange {
        PluginRowChange(rowIndex: 0, type: type, cellChanges: cells, originalRow: originalRow)
    }

    @Test("An update becomes ALTER TABLE ... UPDATE keyed on the original row")
    func updateUsesAlterTable() {
        let statements = driver.generateStatements(
            table: table,
            columns: columns,
            primaryKeyColumns: ["id"],
            changes: [change(
                .update,
                cells: [(columnIndex: 1, columnName: "name", oldValue: .text("Alice"), newValue: .text("Bob"))],
                originalRow: [.text("1"), .text("Alice")]
            )],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(statements?.count == 1)
        let sql = statements?.first?.statement ?? ""
        #expect(sql.hasPrefix("ALTER TABLE"))
        #expect(sql.contains("UPDATE"))
        #expect(sql.contains("WHERE"))
        #expect(sql.contains("`users`"))
    }

    @Test("A delete becomes ALTER TABLE ... DELETE WHERE")
    func deleteUsesAlterTable() {
        let statements = driver.generateStatements(
            table: table,
            columns: columns,
            primaryKeyColumns: ["id"],
            changes: [change(.delete, originalRow: [.text("1"), .text("Alice")])],
            insertedRowData: [:],
            deletedRowIndices: [0],
            insertedRowIndices: []
        )

        #expect(statements?.count == 1)
        let sql = statements?.first?.statement ?? ""
        #expect(sql.hasPrefix("ALTER TABLE"))
        #expect(sql.contains("DELETE WHERE"))
        #expect(sql.contains("`users`"))
    }

    /// Inserts are ordinary. Only the two mutating statements need the ALTER form, and asserting it
    /// here keeps a later change from applying it where it does not belong.
    @Test("An insert stays a plain INSERT")
    func insertStaysPlain() {
        let statements = driver.generateStatements(
            table: table,
            columns: columns,
            primaryKeyColumns: ["id"],
            changes: [change(.insert)],
            insertedRowData: [0: [.text("7"), .text("Carol")]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        let sql = statements?.first?.statement ?? ""
        #expect(sql.hasPrefix("INSERT INTO"))
        #expect(!sql.contains("ALTER TABLE"))
    }

    @Test("An update and a delete match the row on every column it was read with", arguments: [["id"], []])
    func writesMatchTheWholeRow(primaryKeyColumns: [String]) {
        let original: [PluginCellValue] = [.text("1"), .null]
        let statements = driver.generateStatements(
            table: table,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            changes: [
                PluginRowChange(
                    rowIndex: 0,
                    type: .update,
                    cellChanges: [(columnIndex: 1, columnName: "name", oldValue: .null, newValue: .text("Bob"))],
                    originalRow: original
                ),
                PluginRowChange(rowIndex: 1, type: .delete, cellChanges: [], originalRow: original),
            ],
            insertedRowData: [:],
            deletedRowIndices: [1],
            insertedRowIndices: []
        )

        #expect(statements?.map { $0.statement } == [
            "ALTER TABLE `users` UPDATE `name` = ? WHERE `id` = ? AND `name` IS NULL",
            "ALTER TABLE `users` DELETE WHERE `id` = ? AND `name` IS NULL",
        ])
        #expect(statements?.map { $0.parameters } == [[.text("Bob"), .text("1")], [.text("1")]])
    }

    @Test("A change with no row to match writes nothing rather than an unfiltered mutation")
    func changeWithoutOriginalRowWritesNothing() {
        let statements = driver.generateStatements(
            table: table,
            columns: columns,
            primaryKeyColumns: ["id"],
            changes: [
                change(.update, cells: [(columnIndex: 1, columnName: "name", oldValue: .text("a"), newValue: .text("b"))]),
                PluginRowChange(rowIndex: 1, type: .delete, cellChanges: [], originalRow: nil),
            ],
            insertedRowData: [:],
            deletedRowIndices: [1],
            insertedRowIndices: []
        )

        #expect(statements == nil)
    }

    /// A row the caller did not mark deleted is skipped, so a stale change cannot delete anything.
    @Test("A delete not listed in deletedRowIndices produces nothing")
    func unlistedDeleteIsSkipped() {
        let statements = driver.generateStatements(
            table: table,
            columns: columns,
            primaryKeyColumns: ["id"],
            changes: [change(.delete, originalRow: [.text("1"), .text("Alice")])],
            insertedRowData: [:],
            deletedRowIndices: [],
            insertedRowIndices: []
        )

        #expect(statements == nil)
    }

    @Test("A keyed update from an import or a sync is a mutation that waits for itself")
    func rowUpdateWaitsForTheMutation() {
        let driver = driver
        driver.serverProfile = .testing(writableSettings: [.mutationsSync])

        let statement = driver.rowUpdateStatement(table: "`db`.`users`", assignments: "`name` = ?", predicate: "`id` = ?")

        #expect(statement == "ALTER TABLE `db`.`users` UPDATE `name` = ? WHERE `id` = ? SETTINGS mutations_sync = 1")
    }

    @Test("A user who may not change mutations_sync gets the plain UPDATE, which never runs in the background", arguments: [
        ClickHouseServerProfile.testing(),
        ClickHouseServerProfile(
            version: nil,
            settingLimits: [.mutationsSync: ClickHouseSettingLimits(max: 0)],
            catalog: []
        ),
    ])
    func rowUpdateWithoutTheSetting(profile: ClickHouseServerProfile) {
        let driver = driver
        driver.serverProfile = profile

        #expect(driver.rowUpdateStatement(table: "`users`", assignments: "`name` = 'b'", predicate: "`id` = 1") == nil)
        #expect(driver.rowDeleteStatement(table: "`users`", predicate: "`id` = 1") == nil)
        #expect(driver.rowDeleteStatement(table: "`users`", predicate: nil) == "TRUNCATE TABLE `users`")
    }

    @Test("A keyed delete from a sync is a waited mutation, and emptying the table truncates it")
    func rowDeleteForms() {
        let driver = driver
        driver.serverProfile = .testing(writableSettings: [.mutationsSync])

        #expect(driver.rowDeleteStatement(table: "`users`", predicate: "`id` = 1")
            == "ALTER TABLE `users` DELETE WHERE `id` = 1 SETTINGS mutations_sync = 1")
        #expect(driver.rowDeleteStatement(table: "`db`.`users`", predicate: nil) == "TRUNCATE TABLE `db`.`users`")
    }

    @Test("The immutable columns are the ones in the sorting, primary or partition key")
    func immutableColumnsQuery() {
        #expect(ClickHousePluginDriver.immutableColumnsSQL(table: "events", schema: "logs") == """
            SELECT name FROM system.columns
            WHERE database = 'logs' AND table = 'events'
            AND (is_in_sorting_key OR is_in_primary_key OR is_in_partition_key)
            """)
    }
}
