//
//  CompareReviewFindingTests.swift
//  TableProTests
//
//  One test per defect a review of this feature turned up. Each fails against the code as it stood
//  before the fix, which is the only reason to keep them together in one file.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct CompareRetentionCapTests {
    private func engine(limit: Int) -> DataDiffEngine {
        var options = DataCompareOptions()
        options.maxRetainedEntries = limit
        return DataDiffEngine(
            options: options,
            shape: DataComparisonShape(keyColumns: ["id"], keyOrders: [.numeric], comparedColumns: ["name"])
        )
    }

    private func row(_ id: Int, name: String) -> DataRow {
        DataRow(values: ["id": .text(String(format: "%06d", id)), "name": .text(name)])
    }

    /// Identical rows used to consume the retained list, so a table with thousands of matches and
    /// a difference at the end reported the difference in the count and listed nothing.
    @Test
    func identicalRowsDoNotCrowdDifferencesOutOfTheRetainedList() async throws {
        var source: [DataRow] = (1 ... 50).map { row($0, name: "same") }
        var target: [DataRow] = (1 ... 50).map { row($0, name: "same") }
        source.append(row(51, name: "changed"))
        target.append(row(51, name: "original"))

        let summary = try await engine(limit: 10).compare(
            source: ArrayRowProvider(rows: source),
            target: ArrayRowProvider(rows: target)
        )

        #expect(summary.identicalCount == 50, "matches are still counted exactly")
        #expect(summary.updateCount == 1)
        #expect(summary.entries.count == 1, "only the difference is retained")
        #expect(summary.entries[0].kind == .update)
        #expect(!summary.truncatedEntries, "one difference is well inside the cap")
    }

    @Test
    func theCapStillAppliesToDifferences() async throws {
        let source = (1 ... 20).map { row($0, name: "n") }

        let summary = try await engine(limit: 5).compare(
            source: ArrayRowProvider(rows: source),
            target: ArrayRowProvider(rows: [])
        )

        #expect(summary.insertCount == 20)
        #expect(summary.entries.count == 5)
        #expect(summary.truncatedEntries)
    }
}

struct CompareKeyIdentityTests {
    /// Excluding one row from a sync keys on this string, so two different composite keys rendering
    /// the same silently excluded the wrong row.
    @Test
    func twoCompositeKeysThatReadAlikeHaveDistinctIdentities() {
        let first: [PluginCellValue] = [.text("a"), .text("b, c")]
        let second: [PluginCellValue] = [.text("a, b"), .text("c")]

        #expect(KeyOrdering.description(of: first) == KeyOrdering.description(of: second))
        #expect(KeyOrdering.identity(of: first) != KeyOrdering.identity(of: second))
    }

    @Test
    func theSameKeyAlwaysHasTheSameIdentity() {
        let key: [PluginCellValue] = [.text("tenant"), .text("42")]

        #expect(KeyOrdering.identity(of: key) == KeyOrdering.identity(of: key))
    }

    @Test
    func aSingleKeyIdentityMatchesItsDescription() {
        #expect(KeyOrdering.identity(of: [.text("42")]) == KeyOrdering.description(of: [.text("42")]))
    }

    @Test
    func anEntryCarriesBothTheReadableKeyAndItsIdentity() {
        let entry = RowDiffEntry(
            kind: .insert,
            keyDescription: "a, b",
            keyIdentity: "a\u{1F}b",
            sourceRow: nil,
            targetRow: nil
        )

        #expect(entry.keyDescription == "a, b")
        #expect(entry.keyIdentity == "a\u{1F}b")
    }

    @Test
    func anEntryWithNoExplicitIdentityFallsBackToItsDescription() {
        let entry = RowDiffEntry(kind: .insert, keyDescription: "42", sourceRow: nil, targetRow: nil)

        #expect(entry.keyIdentity == "42")
    }
}

struct CompareSchemaMatchingTests {
    private func snapshot(_ name: String, schema: String?) -> TableStructureSnapshot {
        TableStructureSnapshot(
            name: name,
            schema: schema,
            columns: [
                EditableColumnDefinition(
                    id: UUID(),
                    name: "id",
                    dataType: "int",
                    isNullable: false,
                    defaultValue: nil,
                    autoIncrement: false,
                    unsigned: false,
                    comment: nil,
                    collation: nil,
                    onUpdate: nil,
                    charset: nil,
                    extra: nil,
                    isPrimaryKey: true
                )
            ]
        )
    }

    /// Matching on the bare name collapsed two schemas' same-named tables onto one result, diffed
    /// both against whichever target arrived first, and never reported the other as target-only.
    @Test
    func twoSchemasSharingATableNameAreComparedSeparately() {
        let report = StructureDiffEngine().compare(
            source: [snapshot("users", schema: "public"), snapshot("users", schema: "audit")],
            target: [snapshot("users", schema: "public")]
        )

        #expect(report.results.count == 2)
        #expect(report.count(of: .identical) == 1)
        #expect(report.count(of: .onlyInSource) == 1)
    }

    @Test
    func aTargetOnlyTableInASecondSchemaIsReported() {
        let report = StructureDiffEngine().compare(
            source: [snapshot("users", schema: "public")],
            target: [snapshot("users", schema: "public"), snapshot("users", schema: "audit")]
        )

        #expect(report.count(of: .onlyInTarget) == 1)
    }

    @Test
    func aSchemalessEngineStillMatchesOnNameAlone() {
        let report = StructureDiffEngine().compare(
            source: [snapshot("users", schema: nil)],
            target: [snapshot("users", schema: nil)]
        )

        #expect(report.count(of: .identical) == 1)
    }

    @Test
    func matchKeyIgnoresSchemaWhenOnlyOneSideHasOne() {
        let options = StructureCompareOptions.default

        #expect(options.matchKey(name: "users", schema: nil) == options.matchKey("users"))
        #expect(options.matchKey(name: "users", schema: "audit") != options.matchKey(name: "users", schema: "public"))
    }
}

struct CompareRunResultTests {
    /// A commit that threw used to propagate past the whole run, so the result was discarded and
    /// the user got an error with no record of which statements had already executed.
    @Test
    func aCommitFailureIsCarriedOnTheResultRatherThanReplacingIt() {
        let statement = SyncStatement(sql: "A;", objectName: "t", summary: "A")
        let result = CompareSyncRunResult(
            outcomes: [SyncStatementOutcome(id: statement.id, statement: statement, error: nil, wasSkipped: false)],
            rolledBack: false,
            cancelled: false,
            commitFailure: "deadlock detected"
        )

        #expect(result.executedCount == 1, "the per-statement record survives a failed commit")
        #expect(result.commitFailure == "deadlock detected")
    }

    @Test
    func aSuccessfulRunCarriesNoCommitFailure() {
        let result = CompareSyncRunResult(outcomes: [], rolledBack: false, cancelled: false)

        #expect(result.commitFailure == nil)
    }
}

struct CompareDataPlanSchemaTests {
    /// The target used to be read with the source's schema name, so a comparison of `audit.users`
    /// took `public.users`' columns while reading `audit.users`' rows.
    @Test
    func aPlanRemembersTheTargetsOwnSchema() {
        let plan = DataComparePlan(
            table: "users",
            schema: "public",
            targetSchema: "audit",
            columns: [CompareColumn(name: "id")],
            scope: DataTableScope(keyColumns: ["id"]),
            isEnabled: true
        )

        #expect(plan.schema == "public")
        #expect(plan.targetSchema == "audit")
    }

    @Test
    func aPlanWithNoTargetSchemaMirrorsTheSource() {
        let plan = DataComparePlan(
            table: "users",
            schema: "public",
            columns: [CompareColumn(name: "id")],
            scope: DataTableScope(keyColumns: ["id"]),
            isEnabled: true
        )

        #expect(plan.targetSchema == "public")
    }
}
