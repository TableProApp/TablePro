//
//  DataSyncScriptBuilderTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import XCTest

@testable import TablePro

/// `sqlLiteral(for:)` lives only in a protocol extension, so it is statically dispatched and
/// cannot be overridden here. These tests assert against the shared default, which emits
/// numeric-looking text bare unless the target column type says the value is not a number.
private final class PlanQuotingDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let opening: String
    private let closing: String

    init(opening: String = "`", closing: String = "`") {
        self.opening = opening
        self.closing = closing
    }

    func quoteIdentifier(_ name: String) -> String { "\(opening)\(name)\(closing)" }

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

private enum PlanSyncFixture {
    static let defaultColumns = [
        CompareColumn(name: "id", sourceType: "INTEGER", targetType: "INTEGER"),
        CompareColumn(name: "name", sourceType: "VARCHAR(100)", targetType: "VARCHAR(100)")
    ]

    static func makeOptions(insert: Bool = true, update: Bool = true, delete: Bool = true) -> DataCompareOptions {
        var options = DataCompareOptions()
        options.insertMissingRows = insert
        options.updateDifferingRows = update
        options.deleteExtraRows = delete
        return options
    }

    static func makePlan(
        table: String = "users",
        schema: String? = nil,
        targetSchema: String? = nil,
        columns: [CompareColumn] = PlanSyncFixture.defaultColumns,
        keys: [String] = ["id"],
        excluded: Set<String> = []
    ) -> DataComparePlan {
        DataComparePlan(
            table: table,
            schema: schema,
            targetSchema: targetSchema,
            columns: columns,
            scope: DataTableScope(keyColumns: keys, excludedColumns: excluded),
            isEnabled: true
        )
    }

    static func driver(for databaseType: DatabaseType) -> PlanQuotingDriver {
        switch databaseType {
        case .mssql:
            return PlanQuotingDriver(opening: "[", closing: "]")
        case .postgresql, .pglite:
            return PlanQuotingDriver(opening: "\"", closing: "\"")
        default:
            return PlanQuotingDriver()
        }
    }

    static func makeBuilder(
        plan: DataComparePlan = PlanSyncFixture.makePlan(),
        databaseType: DatabaseType = .mysql,
        options: DataCompareOptions = PlanSyncFixture.makeOptions()
    ) -> DataSyncScriptBuilder {
        DataSyncScriptBuilder(
            targetDriver: driver(for: databaseType),
            targetDatabaseType: databaseType,
            options: options,
            plan: plan
        )
    }

    static func build(
        _ entries: [RowDiffEntry],
        plan: DataComparePlan = PlanSyncFixture.makePlan(),
        databaseType: DatabaseType = .mysql,
        options: DataCompareOptions = PlanSyncFixture.makeOptions()
    ) -> [SyncStatement] {
        makeBuilder(plan: plan, databaseType: databaseType, options: options).build(entries: entries)
    }

    static func insertEntry(_ values: [String: PluginCellValue], key: String = "1") -> RowDiffEntry {
        RowDiffEntry(kind: .insert, keyDescription: key, sourceRow: DataRow(values: values), targetRow: nil)
    }

    static func deleteEntry(_ values: [String: PluginCellValue], key: String = "1") -> RowDiffEntry {
        RowDiffEntry(kind: .delete, keyDescription: key, sourceRow: nil, targetRow: DataRow(values: values))
    }

    static func updateEntry(
        source: [String: PluginCellValue],
        target: [String: PluginCellValue],
        changed: [String],
        key: String = "1"
    ) -> RowDiffEntry {
        let sourceRow = DataRow(values: source)
        let targetRow = DataRow(values: target)
        return RowDiffEntry(
            kind: .update,
            keyDescription: key,
            sourceRow: sourceRow,
            targetRow: targetRow,
            cellDifferences: changed.map {
                CellDifference(
                    column: $0,
                    rule: .exactValue,
                    sourceValue: sourceRow.value(for: $0),
                    targetValue: targetRow.value(for: $0)
                )
            }
        )
    }

    /// One row of each kind, handed over out of order, so a test can assert the buckets and the
    /// order they flatten in at the same time.
    static func mixedEntries() -> [RowDiffEntry] {
        [
            deleteEntry(["id": .text("3"), "name": .text("z")], key: "3"),
            updateEntry(
                source: ["id": .text("2"), "name": .text("a")],
                target: ["id": .text("2"), "name": .text("b")],
                changed: ["name"],
                key: "2"
            ),
            insertEntry(["id": .text("1"), "name": .text("c")], key: "1")
        ]
    }

    static func verbs(_ statements: [SyncStatement]) -> [String] {
        statements.map { String($0.sql.prefix(6)) }
    }
}

final class DataSyncScriptBuilderTests: XCTestCase {
    func testInsertQuotesIdentifiersAndEscapesValues() {
        let entry = PlanSyncFixture.insertEntry(["id": .text("1"), "name": .text("O'Hara")])

        let statements = PlanSyncFixture.build([entry])

        XCTAssertEqual(statements.map(\.sql), ["INSERT INTO `users` (`id`, `name`) VALUES (1, 'O''Hara');"])
    }

    func testInsertQualifiesWithTheSchemaWhenTheTableHasOne() {
        let entry = PlanSyncFixture.insertEntry(["id": .text("1"), "name": .text("a")])

        let statements = PlanSyncFixture.build([entry], plan: PlanSyncFixture.makePlan(schema: "app"))

        XCTAssertEqual(statements.map(\.sql), ["INSERT INTO `app`.`users` (`id`, `name`) VALUES (1, 'a');"])
    }

    func testUpdateSetsNonKeyColumnsAndKeysTheWhereClause() {
        let entry = PlanSyncFixture.updateEntry(
            source: ["id": .text("1"), "name": .text("new")],
            target: ["id": .text("1"), "name": .text("old")],
            changed: ["name"]
        )

        let statements = PlanSyncFixture.build([entry])

        XCTAssertEqual(statements.map(\.sql), ["UPDATE `users` SET `name` = 'new' WHERE `id` = 1;"])
    }

    func testUpdateIsSkippedWhenEveryColumnIsAnUnchangedKey() {
        let plan = PlanSyncFixture.makePlan(columns: [CompareColumn(name: "id", targetType: "INTEGER")])
        let entry = PlanSyncFixture.updateEntry(source: ["id": .text("1")], target: ["id": .text("1")], changed: [])

        XCTAssertTrue(PlanSyncFixture.build([entry], plan: plan).isEmpty)
    }

    func testCompositeKeyProducesConjunctionInWhereClause() {
        let plan = PlanSyncFixture.makePlan(
            columns: [
                CompareColumn(name: "tenant", targetType: "VARCHAR(20)"),
                CompareColumn(name: "id", targetType: "INTEGER"),
                CompareColumn(name: "name", targetType: "VARCHAR(100)")
            ],
            keys: ["tenant", "id"]
        )
        let entry = PlanSyncFixture.updateEntry(
            source: ["tenant": .text("a"), "id": .text("1"), "name": .text("new")],
            target: ["tenant": .text("a"), "id": .text("1"), "name": .text("old")],
            changed: ["name"],
            key: "a, 1"
        )

        let statements = PlanSyncFixture.build([entry], plan: plan)

        XCTAssertEqual(
            statements.map(\.sql),
            ["UPDATE `users` SET `name` = 'new' WHERE `tenant` = 'a' AND `id` = 1;"]
        )
    }

    func testDeleteIsKeyedAndCarriesARefusedDataLossHazard() throws {
        let entry = PlanSyncFixture.deleteEntry(["id": .text("7"), "name": .text("x")], key: "7")

        let statements = PlanSyncFixture.build([entry])

        XCTAssertEqual(statements.map(\.sql), ["DELETE FROM `users` WHERE `id` = 7;"])
        let delete = try XCTUnwrap(statements.first)
        XCTAssertTrue(delete.isRefusedByDefault, "a delete must be held back until it is allowed")
        XCTAssertEqual(delete.hazards.map(\.kind), [.dataLoss])
    }

    func testNullKeyUsesIsNullRatherThanEquality() {
        let entry = PlanSyncFixture.deleteEntry(["id": .null, "name": .text("x")], key: "NULL")

        let statements = PlanSyncFixture.build([entry])

        XCTAssertEqual(statements.map(\.sql), ["DELETE FROM `users` WHERE `id` IS NULL;"])
    }

    func testNullValueIsWrittenAsANullLiteralOnInsert() {
        let entry = PlanSyncFixture.insertEntry(["id": .text("1"), "name": .null])

        let statements = PlanSyncFixture.build([entry])

        XCTAssertEqual(statements.map(\.sql), ["INSERT INTO `users` (`id`, `name`) VALUES (1, NULL);"])
    }

    func testNullValueIsAssignedAsANullLiteralOnUpdate() {
        let entry = PlanSyncFixture.updateEntry(
            source: ["id": .text("1"), "name": .null],
            target: ["id": .text("1"), "name": .text("old")],
            changed: ["name"]
        )

        let statements = PlanSyncFixture.build([entry])

        XCTAssertEqual(statements.map(\.sql), ["UPDATE `users` SET `name` = NULL WHERE `id` = 1;"])
    }

    func testDisabledActionsProduceNoStatements() {
        let options = PlanSyncFixture.makeOptions(insert: false, update: false, delete: false)

        let statements = PlanSyncFixture.build(PlanSyncFixture.mixedEntries(), options: options)

        XCTAssertTrue(statements.isEmpty)
    }

    func testEachActionToggleGatesOnlyItsOwnKind() {
        let options = PlanSyncFixture.makeOptions(update: false)

        let statements = PlanSyncFixture.build(PlanSyncFixture.mixedEntries(), options: options)

        XCTAssertEqual(PlanSyncFixture.verbs(statements), ["INSERT", "DELETE"])
    }

    func testIdenticalAndConflictRowsNeverProduceStatements() {
        let identical = RowDiffEntry(
            kind: .identical,
            keyDescription: "1",
            sourceRow: DataRow(values: ["id": .text("1"), "name": .text("a")]),
            targetRow: DataRow(values: ["id": .text("1"), "name": .text("a")])
        )
        let conflict = RowDiffEntry(
            kind: .conflict,
            keyDescription: "2",
            sourceRow: DataRow(values: ["id": .text("2"), "name": .text("a")]),
            targetRow: DataRow(values: ["id": .text("2"), "name": .text("b")])
        )

        XCTAssertTrue(PlanSyncFixture.build([identical, conflict]).isEmpty)
    }

    func testInsertsComeBeforeUpdatesWhichComeBeforeDeletes() {
        let statements = PlanSyncFixture.build(PlanSyncFixture.mixedEntries())

        XCTAssertEqual(PlanSyncFixture.verbs(statements), ["INSERT", "UPDATE", "DELETE"])
    }

    /// Every row statement targets exactly one keyed row, so the executor can catch a predicate
    /// that reached none or several.
    func testEveryRowStatementExpectsExactlyOneAffectedRow() {
        let statements = PlanSyncFixture.build(PlanSyncFixture.mixedEntries())

        XCTAssertEqual(statements.map(\.expectedRowCount), [1, 1, 1])
    }
}

final class DataSyncScriptBuilderPlanTests: XCTestCase {
    /// The source table lives in `staging` and the target in `public`, so qualifying with the
    /// source schema would aim every write at the table the comparison read from.
    func testStatementsAreQualifiedWithTheTargetSchemaNeverTheSourceSchema() {
        let plan = PlanSyncFixture.makePlan(schema: "staging", targetSchema: "public")

        let statements = PlanSyncFixture.build(
            PlanSyncFixture.mixedEntries(), plan: plan, databaseType: .postgresql
        )

        XCTAssertEqual(statements.map(\.sql), [
            #"INSERT INTO "public"."users" ("id", "name") VALUES (1, 'c');"#,
            #"UPDATE "public"."users" SET "name" = 'a' WHERE "id" = 2;"#,
            #"DELETE FROM "public"."users" WHERE "id" = 3;"#
        ])
        XCTAssertFalse(statements.contains { $0.sql.contains("staging") })
    }

    /// The run-wide options carry no key list at all, so the plan's own scope is the only place a
    /// key predicate can come from.
    func testUpdateAndDeleteAreGeneratedFromThePlansKeyColumns() {
        var options = DataCompareOptions()
        options.deleteExtraRows = true
        let plan = PlanSyncFixture.makePlan(
            table: "accounts",
            columns: [
                CompareColumn(name: "account_id", targetType: "BIGINT"),
                CompareColumn(name: "balance", targetType: "DECIMAL(10,2)")
            ],
            keys: ["account_id"]
        )
        let entries = [
            PlanSyncFixture.updateEntry(
                source: ["account_id": .text("42"), "balance": .text("12.50")],
                target: ["account_id": .text("42"), "balance": .text("9.00")],
                changed: ["balance"],
                key: "42"
            ),
            PlanSyncFixture.deleteEntry(["account_id": .text("77"), "balance": .text("0")], key: "77")
        ]

        let statements = PlanSyncFixture.build(entries, plan: plan, options: options)

        XCTAssertEqual(statements.map(\.sql), [
            "UPDATE `accounts` SET `balance` = 12.50 WHERE `account_id` = 42;",
            "DELETE FROM `accounts` WHERE `account_id` = 77;"
        ])
    }

    /// Without a key there is no predicate that names one row, so an unkeyed table can only be
    /// inserted into.
    func testUpdateAndDeleteAreSkippedWhenThePlanHasNoKeyColumns() {
        let plan = PlanSyncFixture.makePlan(keys: [])

        let statements = PlanSyncFixture.build(PlanSyncFixture.mixedEntries(), plan: plan)

        XCTAssertEqual(PlanSyncFixture.verbs(statements), ["INSERT"])
    }

    /// A bare `007` in a VARCHAR column is stored as `7`, and the source column type is not the
    /// one that decides: the value lands in the target's column.
    func testTextValuesAreTypedByTheTargetColumnType() {
        let plan = PlanSyncFixture.makePlan(
            columns: [
                CompareColumn(name: "id", targetType: "INTEGER"),
                CompareColumn(name: "code", sourceType: "INTEGER", targetType: "VARCHAR(10)"),
                CompareColumn(name: "qty", sourceType: "VARCHAR(10)", targetType: "INTEGER")
            ]
        )
        let entry = PlanSyncFixture.insertEntry(["id": .text("1"), "code": .text("007"), "qty": .text("7")])

        let statements = PlanSyncFixture.build([entry], plan: plan)

        XCTAssertEqual(
            statements.map(\.sql),
            ["INSERT INTO `users` (`id`, `code`, `qty`) VALUES (1, '007', 7);"]
        )
    }

    func testTargetColumnTypeFallsBackToTheSourceTypeWhenTheTargetHasNone() {
        let plan = PlanSyncFixture.makePlan(
            columns: [
                CompareColumn(name: "id", targetType: "INTEGER"),
                CompareColumn(name: "code", sourceType: "VARCHAR(10)")
            ]
        )
        let entry = PlanSyncFixture.insertEntry(["id": .text("1"), "code": .text("007")])

        let statements = PlanSyncFixture.build([entry], plan: plan)

        XCTAssertEqual(statements.map(\.sql), ["INSERT INTO `users` (`id`, `code`) VALUES (1, '007');"])
    }

    /// A bare `007` against a VARCHAR key widens the predicate to every row MySQL coerces to 7.
    func testNumericLookingTextKeyIsQuotedInThePredicate() {
        let plan = PlanSyncFixture.makePlan(
            columns: [
                CompareColumn(name: "code", targetType: "VARCHAR(10)"),
                CompareColumn(name: "name", targetType: "VARCHAR(100)")
            ],
            keys: ["code"]
        )
        let entry = PlanSyncFixture.deleteEntry(["code": .text("007"), "name": .text("x")], key: "007")

        let statements = PlanSyncFixture.build([entry], plan: plan)

        XCTAssertEqual(statements.map(\.sql), ["DELETE FROM `users` WHERE `code` = '007';"])
    }

    /// Two keys that matched under a case-insensitive collation still differ byte for byte, so the
    /// predicate has to carry the target's spelling while SET carries the source's.
    func testUpdateMatchesTheTargetKeyAndAssignsTheSourceKeyWhenItDiffers() {
        let plan = keyedByCode()
        let entry = PlanSyncFixture.updateEntry(
            source: ["code": .text("ABC"), "name": .text("new")],
            target: ["code": .text("abc"), "name": .text("old")],
            changed: ["code", "name"],
            key: "ABC"
        )

        let statements = PlanSyncFixture.build([entry], plan: plan)

        XCTAssertEqual(
            statements.map(\.sql),
            ["UPDATE `users` SET `name` = 'new', `code` = 'ABC' WHERE `code` = 'abc';"]
        )
    }

    func testUnchangedKeyIsNeverAssignedInSet() {
        let plan = keyedByCode()
        let entry = PlanSyncFixture.updateEntry(
            source: ["code": .text("abc"), "name": .text("new")],
            target: ["code": .text("abc"), "name": .text("old")],
            changed: ["name"],
            key: "abc"
        )

        let statements = PlanSyncFixture.build([entry], plan: plan)

        XCTAssertEqual(statements.map(\.sql), ["UPDATE `users` SET `name` = 'new' WHERE `code` = 'abc';"])
    }

    /// An excluded column is left out of the comparison so an `updated_at` does not make every row
    /// read as different. It is still carried across.
    func testExcludedColumnIsStillWrittenOnInsertAndUpdate() {
        let plan = PlanSyncFixture.makePlan(
            columns: [
                CompareColumn(name: "id", targetType: "INTEGER"),
                CompareColumn(name: "name", targetType: "VARCHAR(100)"),
                CompareColumn(name: "updated_at", targetType: "TIMESTAMP")
            ],
            excluded: ["updated_at"]
        )
        let entries = [
            PlanSyncFixture.insertEntry([
                "id": .text("1"), "name": .text("a"), "updated_at": .text("2026-01-01 10:00:00")
            ]),
            PlanSyncFixture.updateEntry(
                source: ["id": .text("2"), "name": .text("b"), "updated_at": .text("2026-02-02 10:00:00")],
                target: ["id": .text("2"), "name": .text("c"), "updated_at": .text("2026-01-01 00:00:00")],
                changed: ["name"],
                key: "2"
            )
        ]

        let statements = PlanSyncFixture.build(entries, plan: plan)

        XCTAssertEqual(statements.map(\.sql), [
            "INSERT INTO `users` (`id`, `name`, `updated_at`) VALUES (1, 'a', '2026-01-01 10:00:00');",
            "UPDATE `users` SET `name` = 'b', `updated_at` = '2026-02-02 10:00:00' WHERE `id` = 2;"
        ])
    }

    /// The engine rejects an explicit value for a generated column, so it is read and compared but
    /// never written.
    func testColumnGeneratedOnTheTargetIsNeverWritten() {
        let plan = generatedNameUpper()
        let entries = [
            PlanSyncFixture.insertEntry(["id": .text("1"), "name": .text("a"), "name_upper": .text("A")]),
            PlanSyncFixture.updateEntry(
                source: ["id": .text("2"), "name": .text("b"), "name_upper": .text("B")],
                target: ["id": .text("2"), "name": .text("c"), "name_upper": .text("C")],
                changed: ["name", "name_upper"],
                key: "2"
            )
        ]

        let statements = PlanSyncFixture.build(entries, plan: plan)

        XCTAssertEqual(statements.map(\.sql), [
            "INSERT INTO `users` (`id`, `name`) VALUES (1, 'a');",
            "UPDATE `users` SET `name` = 'b' WHERE `id` = 2;"
        ])
    }

    func testUpdateIsSkippedWhenOnlyAGeneratedColumnDiffers() {
        let plan = PlanSyncFixture.makePlan(
            columns: [
                CompareColumn(name: "id", targetType: "INTEGER"),
                CompareColumn(name: "total", targetType: "INTEGER", isGeneratedOnTarget: true)
            ]
        )
        let entry = PlanSyncFixture.updateEntry(
            source: ["id": .text("1"), "total": .text("9")],
            target: ["id": .text("1"), "total": .text("8")],
            changed: ["total"]
        )

        XCTAssertTrue(PlanSyncFixture.build([entry], plan: plan).isEmpty)
    }

    private func keyedByCode() -> DataComparePlan {
        PlanSyncFixture.makePlan(
            columns: [
                CompareColumn(name: "code", targetType: "VARCHAR(10)"),
                CompareColumn(name: "name", targetType: "VARCHAR(100)")
            ],
            keys: ["code"]
        )
    }

    private func generatedNameUpper() -> DataComparePlan {
        PlanSyncFixture.makePlan(
            columns: [
                CompareColumn(name: "id", targetType: "INTEGER"),
                CompareColumn(name: "name", targetType: "VARCHAR(100)"),
                CompareColumn(name: "name_upper", targetType: "VARCHAR(100)", isGeneratedOnTarget: true)
            ]
        )
    }
}

final class DataSyncScriptBuilderIdentityTests: XCTestCase {
    /// PostgreSQL and SQL Server both reject an assignment to a `GENERATED ALWAYS` identity column.
    func testIdentityAlwaysColumnIsExcludedFromUpdateSet() {
        let plan = PlanSyncFixture.makePlan(
            targetSchema: "public",
            columns: [
                CompareColumn(name: "id", targetType: "BIGINT"),
                CompareColumn(name: "row_no", targetType: "BIGINT", targetIdentity: .always),
                CompareColumn(name: "name", targetType: "VARCHAR(100)")
            ]
        )
        let entry = PlanSyncFixture.updateEntry(
            source: ["id": .text("1"), "row_no": .text("5"), "name": .text("new")],
            target: ["id": .text("1"), "row_no": .text("9"), "name": .text("old")],
            changed: ["row_no", "name"]
        )

        let statements = PlanSyncFixture.build([entry], plan: plan, databaseType: .postgresql)

        XCTAssertEqual(statements.map(\.sql), [#"UPDATE "public"."users" SET "name" = 'new' WHERE "id" = 1;"#])
    }

    func testPostgresFamilyInsertIntoAnIdentityAlwaysColumnOverridesTheSystemValue() {
        let entry = PlanSyncFixture.insertEntry(["id": .text("1"), "name": .text("a")])

        for databaseType in [DatabaseType.postgresql, .pglite] {
            let statements = PlanSyncFixture.build(
                [entry], plan: identityPlan(targetSchema: "public"), databaseType: databaseType
            )

            XCTAssertEqual(
                statements.map(\.sql),
                [#"INSERT INTO "public"."users" ("id", "name") OVERRIDING SYSTEM VALUE VALUES (1, 'a');"#],
                databaseType.rawValue
            )
        }
    }

    /// A `BY DEFAULT` identity accepts an explicit value on its own, so the override would only be
    /// noise.
    func testPostgresInsertIntoAByDefaultIdentityColumnIsPlain() {
        let plan = identityPlan(targetSchema: "public", identity: .byDefault)
        let entry = PlanSyncFixture.insertEntry(["id": .text("1"), "name": .text("a")])

        let statements = PlanSyncFixture.build([entry], plan: plan, databaseType: .postgresql)

        XCTAssertEqual(statements.map(\.sql), [#"INSERT INTO "public"."users" ("id", "name") VALUES (1, 'a');"#])
    }

    func testSQLServerBracketsTheInsertsWithAPairedIdentityInsertToggle() throws {
        let plan = identityPlan(schema: "sales", targetSchema: "dbo", type: "INT", textType: "NVARCHAR(50)")
        let entries = [
            PlanSyncFixture.insertEntry(["id": .text("1"), "name": .text("a")], key: "1"),
            PlanSyncFixture.insertEntry(["id": .text("2"), "name": .text("b")], key: "2"),
            PlanSyncFixture.updateEntry(
                source: ["id": .text("3"), "name": .text("new")],
                target: ["id": .text("3"), "name": .text("old")],
                changed: ["name"],
                key: "3"
            )
        ]

        let statements = PlanSyncFixture.build(entries, plan: plan, databaseType: .mssql)

        XCTAssertEqual(statements.map(\.sql), [
            "SET IDENTITY_INSERT [dbo].[users] ON;",
            "INSERT INTO [dbo].[users] ([id], [name]) VALUES (1, N'a');",
            "INSERT INTO [dbo].[users] ([id], [name]) VALUES (2, N'b');",
            "SET IDENTITY_INSERT [dbo].[users] OFF;",
            "UPDATE [dbo].[users] SET [name] = N'new' WHERE [id] = 3;"
        ])
        let open = try XCTUnwrap(statements.first)
        let close = try XCTUnwrap(statements.first { $0.sql.hasSuffix("OFF;") })
        guard case .opens(let openScope, let closingSQL)? = open.sessionEffect else {
            XCTFail("the ON statement must open a session scope")
            return
        }
        guard case .closes(let closeScope)? = close.sessionEffect else {
            XCTFail("the OFF statement must close the session scope")
            return
        }
        XCTAssertEqual(openScope, closeScope)
        XCTAssertEqual(closingSQL, close.sql)
        XCTAssertEqual(statements.map(\.expectedRowCount), [nil, 1, 1, nil, 1])
    }

    /// SQL Server allows `IDENTITY_INSERT` on one table at a time, so two tables cannot share a
    /// scope the executor pairs its ON and OFF by.
    func testIdentityInsertScopesDifferPerTable() throws {
        let entry = PlanSyncFixture.insertEntry(["id": .text("1"), "name": .text("a")])
        let plans = [
            identityPlan(targetSchema: "dbo", type: "INT", textType: "NVARCHAR(50)"),
            identityPlan(table: "orders", targetSchema: "dbo", type: "INT", textType: "NVARCHAR(50)"),
            identityPlan(targetSchema: "audit", type: "INT", textType: "NVARCHAR(50)")
        ]

        let scopes = try plans.map { plan -> String in
            let statements = PlanSyncFixture.build([entry], plan: plan, databaseType: .mssql)
            return try XCTUnwrap(openScope(of: statements), "the ON statement must open a session scope")
        }

        XCTAssertEqual(Set(scopes).count, 3, "each table and schema needs its own scope: \(scopes)")
    }

    func testSQLServerWritesNoIdentityInsertBracketWhenNothingIsInserted() {
        let plan = identityPlan(targetSchema: "dbo", type: "INT", textType: "NVARCHAR(50)")
        let entries = [
            PlanSyncFixture.updateEntry(
                source: ["id": .text("3"), "name": .text("new")],
                target: ["id": .text("3"), "name": .text("old")],
                changed: ["name"],
                key: "3"
            ),
            PlanSyncFixture.deleteEntry(["id": .text("4"), "name": .text("x")], key: "4")
        ]

        let statements = PlanSyncFixture.build(entries, plan: plan, databaseType: .mssql)

        XCTAssertEqual(PlanSyncFixture.verbs(statements), ["UPDATE", "DELETE"])
        XCTAssertFalse(statements.contains { $0.sql.contains("IDENTITY_INSERT") })
    }

    func testDisabledInsertsLeaveNoIdentityInsertBracketBehind() {
        let plan = identityPlan(targetSchema: "dbo", type: "INT", textType: "NVARCHAR(50)")
        let entry = PlanSyncFixture.insertEntry(["id": .text("1"), "name": .text("a")])
        let options = PlanSyncFixture.makeOptions(insert: false)

        let statements = PlanSyncFixture.build([entry], plan: plan, databaseType: .mssql, options: options)

        XCTAssertTrue(statements.isEmpty)
    }

    func testSQLServerTableWithoutAnIdentityColumnIsNotBracketed() {
        let plan = PlanSyncFixture.makePlan(
            targetSchema: "dbo",
            columns: [
                CompareColumn(name: "id", targetType: "INT"),
                CompareColumn(name: "name", targetType: "NVARCHAR(50)")
            ]
        )
        let entry = PlanSyncFixture.insertEntry(["id": .text("1"), "name": .text("a")])

        let statements = PlanSyncFixture.build([entry], plan: plan, databaseType: .mssql)

        XCTAssertEqual(statements.map(\.sql), ["INSERT INTO [dbo].[users] ([id], [name]) VALUES (1, N'a');"])
    }

    /// A generated column is never written, so its identity cannot need an override either.
    func testGeneratedIdentityColumnNeitherOverridesNorIsWritten() {
        let plan = PlanSyncFixture.makePlan(
            targetSchema: "public",
            columns: [
                CompareColumn(name: "id", targetType: "BIGINT"),
                CompareColumn(
                    name: "row_no", targetType: "BIGINT", isGeneratedOnTarget: true, targetIdentity: .always
                ),
                CompareColumn(name: "name", targetType: "VARCHAR(100)")
            ]
        )
        let entry = PlanSyncFixture.insertEntry([
            "id": .text("1"), "row_no": .text("5"), "name": .text("a")
        ])

        let statements = PlanSyncFixture.build([entry], plan: plan, databaseType: .postgresql)

        XCTAssertEqual(statements.map(\.sql), [#"INSERT INTO "public"."users" ("id", "name") VALUES (1, 'a');"#])
    }

    private func openScope(of statements: [SyncStatement]) -> String? {
        guard case .opens(let scope, _)? = statements.first?.sessionEffect else { return nil }
        return scope
    }

    private func identityPlan(
        table: String = "users",
        schema: String? = nil,
        targetSchema: String? = nil,
        identity: IdentityKind = .always,
        type: String = "BIGINT",
        textType: String = "VARCHAR(100)"
    ) -> DataComparePlan {
        PlanSyncFixture.makePlan(
            table: table,
            schema: schema,
            targetSchema: targetSchema,
            columns: [
                CompareColumn(name: "id", targetType: type, targetIdentity: identity),
                CompareColumn(name: "name", targetType: textType)
            ]
        )
    }
}

final class DataSyncScriptBuilderColumnTests: XCTestCase {
    /// PostgreSQL rejects `X'8950'` with "column is of type bytea but expression is of type bit".
    func testBinaryValuesUseTheTargetEnginesSpelling() {
        let statements = PlanSyncFixture.build(
            [binaryInsert()], plan: binaryPlan(targetSchema: "public"), databaseType: .postgresql
        )

        XCTAssertEqual(
            statements.map(\.sql),
            [#"INSERT INTO "public"."files" ("id", "blob") VALUES (1, '\x8950'::bytea);"#]
        )
    }

    func testBitStringEnginesKeepTheirOwnSpelling() {
        let statements = PlanSyncFixture.build([binaryInsert()], plan: binaryPlan())

        XCTAssertEqual(statements.map(\.sql), ["INSERT INTO `files` (`id`, `blob`) VALUES (1, X'8950');"])
    }

    func testSQLServerWritesBinaryAsAZeroXLiteral() {
        let statements = PlanSyncFixture.build(
            [binaryInsert()],
            plan: binaryPlan(targetSchema: "dbo", blobType: "VARBINARY(MAX)"),
            databaseType: .mssql
        )

        XCTAssertEqual(statements.map(\.sql), ["INSERT INTO [dbo].[files] ([id], [blob]) VALUES (1, 0x8950);"])
    }

    /// The three buckets exist so a caller can interleave several tables in dependency order. A
    /// flat per-table inserts+updates+deletes is only correct for one table.
    func testStatementsAreBucketedByKind() {
        var statements = DataSyncStatements()
        XCTAssertTrue(statements.isEmpty)
        let builder = PlanSyncFixture.makeBuilder()

        for entry in PlanSyncFixture.mixedEntries() {
            builder.append(entry, into: &statements)
        }
        builder.finish(&statements)

        XCTAssertEqual(statements.inserts.map(\.sql), ["INSERT INTO `users` (`id`, `name`) VALUES (1, 'c');"])
        XCTAssertEqual(statements.updates.map(\.sql), ["UPDATE `users` SET `name` = 'a' WHERE `id` = 2;"])
        XCTAssertEqual(statements.deletes.map(\.sql), ["DELETE FROM `users` WHERE `id` = 3;"])
        XCTAssertFalse(statements.isEmpty)
        XCTAssertEqual(PlanSyncFixture.verbs(statements.flattened), ["INSERT", "UPDATE", "DELETE"])
    }

    func testFinishBracketsOnlyTheInsertBucket() {
        var statements = DataSyncStatements()
        let builder = PlanSyncFixture.makeBuilder(plan: identityFilesPlan(), databaseType: .mssql)

        for entry in PlanSyncFixture.mixedEntries() {
            builder.append(entry, into: &statements)
        }
        builder.finish(&statements)

        XCTAssertEqual(statements.inserts.map(\.sql), [
            "SET IDENTITY_INSERT [dbo].[files] ON;",
            "INSERT INTO [dbo].[files] ([id], [name]) VALUES (1, N'c');",
            "SET IDENTITY_INSERT [dbo].[files] OFF;"
        ])
        XCTAssertEqual(statements.updates.map(\.sql), ["UPDATE [dbo].[files] SET [name] = N'a' WHERE [id] = 2;"])
        XCTAssertEqual(statements.deletes.map(\.sql), ["DELETE FROM [dbo].[files] WHERE [id] = 3;"])
    }

    func testFinishAddsNothingWhenTheInsertBucketIsEmpty() {
        var statements = DataSyncStatements()
        let builder = PlanSyncFixture.makeBuilder(plan: identityFilesPlan(), databaseType: .mssql)
        let entry = PlanSyncFixture.deleteEntry(["id": .text("3"), "name": .text("z")], key: "3")

        builder.append(entry, into: &statements)
        builder.finish(&statements)

        XCTAssertTrue(statements.inserts.isEmpty)
        XCTAssertEqual(statements.deletes.count, 1)
    }

    private func binaryInsert() -> RowDiffEntry {
        PlanSyncFixture.insertEntry(["id": .text("1"), "blob": .bytes(Data([0x89, 0x50]))])
    }

    private func binaryPlan(targetSchema: String? = nil, blobType: String = "BLOB") -> DataComparePlan {
        PlanSyncFixture.makePlan(
            table: "files",
            targetSchema: targetSchema,
            columns: [
                CompareColumn(name: "id", targetType: "INTEGER"),
                CompareColumn(name: "blob", targetType: blobType)
            ]
        )
    }

    private func identityFilesPlan() -> DataComparePlan {
        PlanSyncFixture.makePlan(
            table: "files",
            targetSchema: "dbo",
            columns: [
                CompareColumn(name: "id", targetType: "INT", targetIdentity: .always),
                CompareColumn(name: "name", targetType: "NVARCHAR(50)")
            ]
        )
    }
}
