//
//  ClickHouseDMLStatementTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

// A ClickHouse row has no key that names it, so every update and delete matches the whole row it was read with,
// finds it with a lookup right before the write, and is pinned to the part the lookup found.
struct ClickHouseDMLStatementTests {
    private let table = "users"
    private let columns = ["id", "name"]

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

    private var waitingDriver: ClickHousePluginDriver {
        let driver = driver
        driver.serverProfile = .testing(writableSettings: [.mutationsSync])
        return driver
    }

    private func writes(
        _ changes: [PluginRowChange],
        driver: ClickHousePluginDriver? = nil,
        columns: [String]? = nil,
        primaryKeyColumns: [String] = ["id"],
        inserted: [Int: [PluginCellValue]] = [:],
        deleted: Set<Int> = [],
        types: [String: String] = [:]
    ) throws -> [PluginRowWrite]? {
        var context = PluginRowWriteContext()
        context.columnTypeNames = types
        return try (driver ?? waitingDriver).generateRowWrites(
            table: table,
            schema: nil,
            columns: columns ?? self.columns,
            primaryKeyColumns: primaryKeyColumns,
            changes: changes,
            insertedRowData: inserted,
            deletedRowIndices: deleted,
            insertedRowIndices: Set(inserted.keys),
            context: context
        )
    }

    private func update(row: Int = 0, original: [PluginCellValue] = ["1", "Alice"], to name: PluginCellValue = "Bob")
        -> PluginRowChange {
        PluginRowChange(
            rowIndex: row,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "name", oldValue: original[1], newValue: name)],
            originalRow: original
        )
    }

    private func delete(row: Int, original: [PluginCellValue]) -> PluginRowChange {
        PluginRowChange(rowIndex: row, type: .delete, cellChanges: [], originalRow: original)
    }

    @Test("An update matches the whole row, not the sorting key, waits for its mutation and is pinned to its part")
    func updateIsPinnedToItsRow() throws {
        let write = try #require(try writes([update()])?.first)

        #expect(write.statement
            == "ALTER TABLE `users` UPDATE `name` = ? WHERE `id` = ? AND `name` = ? AND _part IN (?) SETTINGS mutations_sync = 1")
        #expect(write.parameters == ["Bob", "1", "Alice"])
        #expect(write.rowIndices == [0])
        #expect(write.lookup == PluginRowLookup(
            query: "SELECT _part FROM `users` WHERE `id` = ? AND `name` = ? LIMIT 2",
            parameters: ["1", "Alice"],
            rowCount: 1,
            pinsRows: true,
            check: "SELECT 1 FROM `users` WHERE `id` = ? AND `name` = ? AND NOT ifNull(`name` = ?, 0) LIMIT 1",
            checkParameters: ["1", "Alice", "Bob"]
        ))
    }

    @Test("A delete matches the whole row and is pinned to its part")
    func deleteIsPinnedToItsRow() throws {
        let write = try #require(try writes([delete(row: 0, original: ["1", .null])], deleted: [0])?.first)

        #expect(write.statement
            == "ALTER TABLE `users` DELETE WHERE `id` = ? AND `name` IS NULL AND _part IN (?) SETTINGS mutations_sync = 1")
        #expect(write.parameters == ["1"])
        #expect(write.lookup?.query == "SELECT _part FROM `users` WHERE `id` = ? AND `name` IS NULL LIMIT 2")
        #expect(write.lookup?.rowCount == 1)
        #expect(write.lookup?.check == "SELECT 1 FROM `users` WHERE `id` = ? AND `name` IS NULL LIMIT 1")
    }

    // Measured on 25.8: one ALTER ... DELETE pinned to the parts its lookup found removes exactly those rows.
    @Test("Deleting every copy of an identical row is one write that has to find all of them")
    func identicalDeletesAreOneWrite() throws {
        let row: [PluginCellValue] = ["1", "Alice"]
        let deletes = try #require(try writes(
            [delete(row: 0, original: row), delete(row: 1, original: ["2", "Bob"]), delete(row: 2, original: row)],
            deleted: [0, 1, 2]
        ))

        #expect(deletes.map { $0.rowIndices } == [[0, 2], [1]])
        #expect(deletes[0].statement.contains("AND _part IN (?, ?) SETTINGS"))
        #expect(deletes[0].lookup?.query.hasSuffix(" LIMIT 3") == true)
        #expect(deletes[0].lookup?.rowCount == 2)
    }

    @Test("Rows whose text differs only in its Unicode form are deleted as different rows")
    func unicodeFormsAreNotGrouped() throws {
        let composed: [PluginCellValue] = ["1", .text("caf\u{E9}")]
        let decomposed: [PluginCellValue] = ["1", .text("cafe\u{301}")]

        let deletes = try #require(try writes(
            [delete(row: 0, original: composed), delete(row: 1, original: decomposed)], deleted: [0, 1]
        ))

        #expect(deletes.map { $0.rowIndices } == [[0], [1]])
    }

    @Test("A row deleted and then inserted again with the same values is deleted first")
    func deleteThenInsertKeepsItsOrder() throws {
        let row: [PluginCellValue] = ["1", "Alice"]
        let insert = PluginRowChange(rowIndex: 1, type: .insert, cellChanges: [], originalRow: nil)
        let first = delete(row: 0, original: row)
        let later = delete(row: 2, original: row)

        let ordered = try #require(try writes([first, insert, later], inserted: [1: row], deleted: [0, 2]))

        #expect(ordered.map { $0.rowIndices } == [[0], [1], [2]])
        #expect(ordered.map { $0.statement.hasPrefix("INSERT") } == [false, true, false])
    }

    @Test("A user who may not wait for a mutation gets the lightweight forms, pinned the same way")
    func lightweightFormsWithoutTheSetting() throws {
        let plain = driver
        let update = try #require(try writes([update()], driver: plain)?.first)
        let delete = try #require(try writes([delete(row: 0, original: ["1", "Alice"])], driver: plain, deleted: [0])?.first)

        #expect(update.statement == "UPDATE `users` SET `name` = ? WHERE `id` = ? AND `name` = ? AND _part IN (?)")
        #expect(delete.statement == "DELETE FROM `users` WHERE `id` = ? AND `name` = ? AND _part IN (?)")
    }

    // Measured on 25.8: `j = '{"a":1}'` and `f = 'nan'` match nothing, and their text matches the row.
    @Test("A JSON or float column is matched as the text the grid read, and checked as the server stores it")
    func textMatchedTypes() throws {
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 2, columnName: "score", oldValue: "nan", newValue: "1.50")],
            originalRow: ["1", #"{"a":1}"#, "nan"]
        )
        let write = try #require(try writes(
            [change],
            columns: ["id", "doc", "score"],
            types: ["id": "UInt64", "doc": "JSON", "score": "Nullable(Float64)"]
        )?.first)

        #expect(write.lookup?.query
            == "SELECT _part FROM `users` WHERE `id` = ? AND toString(`doc`) = ? AND toString(`score`) = ? LIMIT 2")
        #expect(write.lookup?.check?.hasSuffix(
            "AND NOT ifNull(toString(`score`) = toString(CAST(? AS Nullable(Float64))), 0) LIMIT 1"
        ) == true)
    }

    // Measured on 25.8: toString of a column equals toString(CAST(text AS its type)) whatever spelling the text has,
    // for every type but Map.
    @Test("A JSON edit is checked against the value as the server stores it")
    func jsonCheckNormalizes() throws {
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "doc", oldValue: #"{"a":1}"#, newValue: #"{"a": 2}"#)],
            originalRow: ["1", #"{"a":1}"#]
        )
        let write = try #require(try writes([change], columns: ["id", "doc"], types: ["id": "UInt64", "doc": "JSON"])?.first)

        #expect(write.lookup?.check?.contains("NOT ifNull(toString(`doc`) = toString(CAST(? AS JSON)), 0)") == true)
    }

    @Test("A Map value, which a String does not cast to, is checked as typed")
    func mapCheckIsTyped() throws {
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "tags", oldValue: "{'a':1}", newValue: "{'b':2}")],
            originalRow: ["1", "{'a':1}"]
        )
        let write = try #require(try writes(
            [change], columns: ["id", "tags"], types: ["id": "UInt64", "tags": "Map(String, UInt64)"]
        )?.first)

        #expect(write.lookup?.check?.contains("NOT ifNull(`tags` = ?, 0)") == true)
    }

    // Measured on 25.8: equals on AggregateFunction(sum, UInt64) is Code 43, not comparable.
    @Test("A row holding an aggregate state is refused, since it cannot be found again")
    func aggregateStateIsRefused() {
        #expect(throws: PluginRowWriteRefusal.self) {
            _ = try writes([update()], types: ["name": "AggregateFunction(sum, UInt64)"])
        }
    }

    @Test("A column the server computes stays out of the match, since its saved value can be stale")
    func serverOwnedColumnsAreNotMatched() throws {
        var context = PluginRowWriteContext()
        context.serverOwnedColumns = ["total"]
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "name", oldValue: "Alice", newValue: "Bob")],
            originalRow: ["1", "Alice", "5"]
        )
        let write = try #require(try waitingDriver.generateRowWrites(
            table: table, schema: nil, columns: ["id", "name", "total"], primaryKeyColumns: [], changes: [change],
            insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: [], context: context
        )?.first)

        #expect(write.lookup?.query == "SELECT _part FROM `users` WHERE `id` = ? AND `name` = ? LIMIT 2")
    }

    @Test("A change with no row to match is refused rather than written unfiltered")
    func changeWithoutOriginalRowIsRefused() {
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: [(columnIndex: 1, columnName: "name", oldValue: "a", newValue: "b")],
            originalRow: nil
        )
        #expect(throws: PluginRowWriteRefusal.self) { _ = try writes([change]) }
    }

    @Test("A delete not listed in deletedRowIndices writes nothing, and an empty set is no statement at all")
    func unlistedDeleteIsSkipped() throws {
        #expect(try writes([delete(row: 0, original: ["1", "Alice"])])?.isEmpty == true)
        #expect(try writes([])?.isEmpty == true)
    }

    @Test("An insert stays a plain INSERT, a SQL cell written as SQL and a defaulted column left out")
    func insertStaysPlain() throws {
        var change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        change.expressionColumns = [1]
        let write = try #require(try writes(
            [change], columns: ["id", "at", "note"], inserted: [0: ["7", "now()", "__DEFAULT__"]]
        )?.first)

        #expect(write.statement == "INSERT INTO `users` (`id`, `at`) VALUES (?, now())")
        #expect(write.parameters == ["7"])
        #expect(write.lookup == nil)
    }

    @Test("A new row that sets nothing takes every default, named through a column the server does not fill")
    func emptyInsertTakesDefaults() throws {
        let change = PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)
        var context = PluginRowWriteContext()
        context.serverOwnedColumns = ["id"]
        let write = try #require(try waitingDriver.generateRowWrites(
            table: table, schema: nil, columns: columns, primaryKeyColumns: [], changes: [change],
            insertedRowData: [0: ["__DEFAULT__", "__DEFAULT__"]], deletedRowIndices: [], insertedRowIndices: [0],
            context: context
        )?.first)

        #expect(write.statement == "INSERT INTO `users` (`name`) VALUES (DEFAULT)")
    }

    @Test("A SQL cell in an update is written as SQL, and the check compares against it")
    func updateExpression() throws {
        var change = update(to: "now()")
        change.expressionColumns = [1]
        let write = try #require(try writes([change])?.first)

        #expect(write.statement.hasPrefix("ALTER TABLE `users` UPDATE `name` = now() WHERE"))
        #expect(write.parameters == ["1", "Alice"])
        #expect(write.lookup?.check?.contains("NOT ifNull(`name` = now(), 0)") == true)
    }

    @Test("A deleted row goes back with every value it had")
    func restoreInsertsEveryValue() {
        let restored = driver.generateIdentityPreservingInsert(
            table: table, schema: nil, columns: columns, primaryKeyColumns: ["id"], rows: [["1", .null]]
        )

        #expect(restored?.map { $0.statement } == ["INSERT INTO `users` (`id`, `name`) VALUES (?, ?)"])
        #expect(restored?.first?.parameters == ["1", .null])
    }

    @Test("The driver says it writes its own rows, SQL cells and UUID text, and that rows share its primary key")
    func declaresRowWrites() {
        #expect(driver.capabilities.isSuperset(of: [.rowWrites, .cellExpressions, .uuidCellText, .repeatingPrimaryKey]))
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
