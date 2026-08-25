//
//  DataSyncScriptBuilderTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import XCTest

@testable import TablePro

/// `sqlLiteral(for:)` lives only in a protocol extension, so it is statically
/// dispatched and cannot be overridden here. These tests assert against the
/// shared default, which emits numeric-looking text as a bare numeric literal.
private final class QuotingDriver: PluginDatabaseDriver, @unchecked Sendable {
    func quoteIdentifier(_ name: String) -> String { "`\(name)`" }

    func connect() async throws {}
    func disconnect() {}
    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
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

final class DataSyncScriptBuilderTests: XCTestCase {
    private let driver = QuotingDriver()

    private func options(
        insert: Bool = true,
        update: Bool = true,
        delete: Bool = true,
        keys: [String] = ["id"]
    ) -> DataCompareOptions {
        var result = DataCompareOptions()
        result.keyColumns = keys
        result.insertMissingRows = insert
        result.updateDifferingRows = update
        result.deleteExtraRows = delete
        return result
    }

    private func row(_ pairs: [String: PluginCellValue]) -> DataRow {
        DataRow(values: pairs)
    }

    private func build(
        entries: [RowDiffEntry],
        options overrides: DataCompareOptions? = nil,
        columns: [String] = ["id", "name"],
        schema: String? = nil
    ) -> [SyncStatement] {
        DataSyncScriptBuilder(
            targetDriver: driver, targetDatabaseType: .mysql, options: overrides ?? options()
        )
            .build(table: "users", schema: schema, writeColumns: columns, entries: entries)
    }

    // MARK: - Insert

    func testInsertQuotesIdentifiersAndEscapesValues() {
        let entry = RowDiffEntry(
            kind: .insert,
            keyDescription: "1",
            sourceRow: row(["id": .text("1"), "name": .text("O'Hara")]),
            targetRow: nil
        )

        let statements = build(entries: [entry])

        XCTAssertEqual(statements.count, 1)
        XCTAssertEqual(
            statements[0].sql,
            "INSERT INTO `users` (`id`, `name`) VALUES (1, 'O''Hara');"
        )
    }

    func testInsertQualifiesWithSchemaWhenPresent() {
        let entry = RowDiffEntry(
            kind: .insert, keyDescription: "1",
            sourceRow: row(["id": .text("1"), "name": .text("a")]), targetRow: nil
        )

        let statements = build(entries: [entry], schema: "app")

        XCTAssertTrue(statements[0].sql.hasPrefix("INSERT INTO `app`.`users`"), statements[0].sql)
    }

    // MARK: - Update

    func testUpdateSetsNonKeyColumnsAndKeysTheWhereClause() {
        let entry = RowDiffEntry(
            kind: .update, keyDescription: "1",
            sourceRow: row(["id": .text("1"), "name": .text("new")]),
            targetRow: row(["id": .text("1"), "name": .text("old")])
        )

        let statements = build(entries: [entry])

        XCTAssertEqual(statements.count, 1)
        XCTAssertEqual(statements[0].sql, "UPDATE `users` SET `name` = 'new' WHERE `id` = 1;")
        XCTAssertFalse(statements[0].sql.contains("SET `id`"), "the key must never be assigned in SET")
    }

    func testUpdateIsSkippedWhenEveryColumnIsAKey() {
        let entry = RowDiffEntry(
            kind: .update, keyDescription: "1",
            sourceRow: row(["id": .text("1")]), targetRow: row(["id": .text("1")])
        )

        let statements = build(entries: [entry], options: options(keys: ["id"]), columns: ["id"])

        XCTAssertTrue(statements.isEmpty, "there is nothing to assign, so no statement should be produced")
    }

    func testCompositeKeyProducesConjunctionInWhereClause() {
        let entry = RowDiffEntry(
            kind: .update, keyDescription: "a, 1",
            sourceRow: row(["tenant": .text("a"), "id": .text("1"), "name": .text("new")]),
            targetRow: row(["tenant": .text("a"), "id": .text("1"), "name": .text("old")])
        )

        let statements = build(
            entries: [entry],
            options: options(keys: ["tenant", "id"]),
            columns: ["tenant", "id", "name"]
        )

        XCTAssertTrue(statements[0].sql.contains("WHERE `tenant` = 'a' AND `id` = 1;"), statements[0].sql)
    }

    // MARK: - Delete

    func testDeleteIsKeyedAndCarriesARefusedHazard() {
        let entry = RowDiffEntry(
            kind: .delete, keyDescription: "7",
            sourceRow: nil, targetRow: row(["id": .text("7"), "name": .text("x")])
        )

        let statements = build(entries: [entry])

        XCTAssertEqual(statements.count, 1)
        XCTAssertEqual(statements[0].sql, "DELETE FROM `users` WHERE `id` = 7;")
        XCTAssertTrue(statements[0].isRefusedByDefault, "a delete must be held back until allowed")
    }

    // MARK: - NULL handling

    func testNullKeyUsesIsNullRatherThanEquality() {
        let entry = RowDiffEntry(
            kind: .delete, keyDescription: "NULL",
            sourceRow: nil, targetRow: row(["id": .null, "name": .text("x")])
        )

        let statements = build(entries: [entry])

        XCTAssertEqual(statements[0].sql, "DELETE FROM `users` WHERE `id` IS NULL;")
    }

    func testNullValueIsWrittenAsNullLiteralOnInsert() {
        let entry = RowDiffEntry(
            kind: .insert, keyDescription: "1",
            sourceRow: row(["id": .text("1"), "name": .null]), targetRow: nil
        )

        let statements = build(entries: [entry])

        XCTAssertTrue(statements[0].sql.hasSuffix("VALUES (1, NULL);"), statements[0].sql)
    }

    // MARK: - Action toggles

    func testDisabledActionsProduceNoStatements() {
        let entries = [
            RowDiffEntry(kind: .insert, keyDescription: "1", sourceRow: row(["id": .text("1")]), targetRow: nil),
            RowDiffEntry(
                kind: .update, keyDescription: "2",
                sourceRow: row(["id": .text("2"), "name": .text("a")]),
                targetRow: row(["id": .text("2"), "name": .text("b")])
            ),
            RowDiffEntry(kind: .delete, keyDescription: "3", sourceRow: nil, targetRow: row(["id": .text("3")]))
        ]

        let statements = build(entries: entries, options: options(insert: false, update: false, delete: false))

        XCTAssertTrue(statements.isEmpty)
    }

    func testIdenticalRowsNeverProduceStatements() {
        let entry = RowDiffEntry(
            kind: .identical, keyDescription: "1",
            sourceRow: row(["id": .text("1")]), targetRow: row(["id": .text("1")])
        )

        XCTAssertTrue(build(entries: [entry]).isEmpty)
    }

    // MARK: - Ordering

    func testInsertsComeBeforeUpdatesWhichComeBeforeDeletes() {
        let entries = [
            RowDiffEntry(kind: .delete, keyDescription: "3", sourceRow: nil, targetRow: row(["id": .text("3")])),
            RowDiffEntry(
                kind: .update, keyDescription: "2",
                sourceRow: row(["id": .text("2"), "name": .text("a")]),
                targetRow: row(["id": .text("2"), "name": .text("b")])
            ),
            RowDiffEntry(
                kind: .insert, keyDescription: "1",
                sourceRow: row(["id": .text("1"), "name": .text("c")]), targetRow: nil
            )
        ]

        let verbs = build(entries: entries).map { String($0.sql.prefix(6)) }

        XCTAssertEqual(verbs, ["INSERT", "UPDATE", "DELETE"])
    }

    // MARK: - Write set

    func testExcludedFromComparisonColumnIsStillWritten() {
        var overrides = options()
        overrides.excludedFromComparison = ["updated_at"]
        let entry = RowDiffEntry(
            kind: .insert, keyDescription: "1",
            sourceRow: row(["id": .text("1"), "name": .text("a"), "updated_at": .text("2026-01-01")]),
            targetRow: nil
        )

        let statements = build(entries: [entry], options: overrides, columns: ["id", "name", "updated_at"])

        XCTAssertTrue(
            statements[0].sql.contains("`updated_at`") && statements[0].sql.contains("'2026-01-01'"),
            "a column excluded from matching must still be written: \(statements[0].sql)"
        )
    }
}

final class DataSyncScriptBuilderColumnTests: XCTestCase {
    private func builder(
        _ databaseType: DatabaseType = .postgresql,
        options: DataCompareOptions
    ) -> DataSyncScriptBuilder {
        DataSyncScriptBuilder(
            targetDriver: QuotingDriver(),
            targetDatabaseType: databaseType,
            options: options
        )
    }

    private func options() -> DataCompareOptions {
        var options = DataCompareOptions()
        options.keyColumns = ["id"]
        options.insertMissingRows = true
        options.updateDifferingRows = true
        options.deleteExtraRows = true
        return options
    }

    private func insertEntry() -> RowDiffEntry {
        RowDiffEntry(
            kind: .insert,
            keyDescription: "1",
            sourceRow: DataRow(values: [
                "id": .text("1"),
                "blob": .bytes(Data([0x89, 0x50])),
                "total": .text("9")
            ]),
            targetRow: nil
        )
    }

    /// PostgreSQL rejects `X'8950'` with "column is of type bytea but expression is of type bit".
    func testBinaryValuesUseTheTargetEnginesSpelling() {
        let statements = builder(.postgresql, options: options()).build(
            table: "files", schema: "public", writeColumns: ["id", "blob"], entries: [insertEntry()]
        )

        XCTAssertEqual(statements.count, 1)
        XCTAssertTrue(statements[0].sql.contains("'\\x8950'::bytea"), statements[0].sql)
        XCTAssertFalse(statements[0].sql.contains("X'"), statements[0].sql)
    }

    func testBitStringEnginesKeepTheirOwnSpelling() {
        let statements = builder(.mysql, options: options()).build(
            table: "files", schema: nil, writeColumns: ["id", "blob"], entries: [insertEntry()]
        )

        XCTAssertTrue(statements[0].sql.contains("X'8950'"), statements[0].sql)
    }

    /// The three buckets exist so a caller can interleave several tables in dependency order. A
    /// flat per-table inserts+updates+deletes is only correct for one table.
    func testStatementsAreBucketedByKind() {
        var statements = DataSyncStatements()
        let entries = [
            insertEntry(),
            RowDiffEntry(
                kind: .delete, keyDescription: "2",
                sourceRow: nil, targetRow: DataRow(values: ["id": .text("2")])
            )
        ]
        let builder = builder(.mysql, options: options())
        for entry in entries {
            builder.append(entry, table: "files", schema: nil, writeColumns: ["id", "blob"], into: &statements)
        }

        XCTAssertEqual(statements.inserts.count, 1)
        XCTAssertEqual(statements.deletes.count, 1)
        XCTAssertTrue(statements.updates.isEmpty)
        XCTAssertFalse(statements.isEmpty)
    }

    func testDeleteStatementsCarryARefusedHazard() {
        var statements = DataSyncStatements()
        builder(.mysql, options: options()).append(
            RowDiffEntry(
                kind: .delete, keyDescription: "2",
                sourceRow: nil, targetRow: DataRow(values: ["id": .text("2")])
            ),
            table: "files", schema: nil, writeColumns: ["id"], into: &statements
        )

        XCTAssertTrue(statements.deletes[0].isRefusedByDefault)
    }
}
