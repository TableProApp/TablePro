//
//  CompareReviewFindingTests.swift
//  TableProTests
//
//  One test per defect a review of this feature turned up. Each fails against the code as it stood
//  before the fix, which is the only reason to keep them together in one file.
//

@testable import TablePro
import TableProPluginKit
import XCTest

final class CompareRetentionCapTests: XCTestCase {
    private func engine(limit: Int) -> DataDiffEngine {
        var options = DataCompareOptions()
        options.keyColumns = ["id"]
        options.maxRetainedEntries = limit
        return DataDiffEngine(
            options: options,
            columns: ["id", "name"],
            keyDescriptors: [KeyColumnDescriptor(name: "id", dataType: "int")]
        )
    }

    private func row(_ id: Int, name: String) -> DataRow {
        DataRow(values: ["id": .text(String(format: "%06d", id)), "name": .text(name)])
    }

    /// Identical rows used to consume the retained list, so a table with thousands of matches and
    /// a difference at the end reported the difference in the count and listed nothing.
    func testIdenticalRowsDoNotCrowdDifferencesOutOfTheRetainedList() async throws {
        var source: [DataRow] = (1 ... 50).map { row($0, name: "same") }
        var target: [DataRow] = (1 ... 50).map { row($0, name: "same") }
        source.append(row(51, name: "changed"))
        target.append(row(51, name: "original"))

        let summary = try await engine(limit: 10).compare(
            source: ArrayRowProvider(rows: source),
            target: ArrayRowProvider(rows: target)
        )

        XCTAssertEqual(summary.identicalCount, 50, "matches are still counted exactly")
        XCTAssertEqual(summary.updateCount, 1)
        XCTAssertEqual(summary.entries.count, 1, "only the difference is retained")
        XCTAssertEqual(summary.entries[0].kind, .update)
        XCTAssertFalse(summary.truncatedEntries, "one difference is well inside the cap")
    }

    func testTheCapStillAppliesToDifferences() async throws {
        let source = (1 ... 20).map { row($0, name: "n") }

        let summary = try await engine(limit: 5).compare(
            source: ArrayRowProvider(rows: source),
            target: ArrayRowProvider(rows: [])
        )

        XCTAssertEqual(summary.insertCount, 20)
        XCTAssertEqual(summary.entries.count, 5)
        XCTAssertTrue(summary.truncatedEntries)
    }
}

final class CompareKeyIdentityTests: XCTestCase {
    /// Excluding one row from a sync keys on this string, so two different composite keys rendering
    /// the same silently excluded the wrong row.
    func testTwoCompositeKeysThatReadAlikeHaveDistinctIdentities() {
        let first: [PluginCellValue] = [.text("a"), .text("b, c")]
        let second: [PluginCellValue] = [.text("a, b"), .text("c")]

        XCTAssertEqual(KeyOrdering.description(of: first), KeyOrdering.description(of: second))
        XCTAssertNotEqual(KeyOrdering.identity(of: first), KeyOrdering.identity(of: second))
    }

    func testTheSameKeyAlwaysHasTheSameIdentity() {
        let key: [PluginCellValue] = [.text("tenant"), .text("42")]

        XCTAssertEqual(KeyOrdering.identity(of: key), KeyOrdering.identity(of: key))
    }

    func testASingleKeyIdentityMatchesItsDescription() {
        XCTAssertEqual(KeyOrdering.identity(of: [.text("42")]), KeyOrdering.description(of: [.text("42")]))
    }

    func testAnEntryCarriesBothTheReadableKeyAndItsIdentity() {
        let entry = RowDiffEntry(
            kind: .insert,
            keyDescription: "a, b",
            keyIdentity: "a\u{1F}b",
            sourceRow: nil,
            targetRow: nil
        )

        XCTAssertEqual(entry.keyDescription, "a, b")
        XCTAssertEqual(entry.keyIdentity, "a\u{1F}b")
    }

    func testAnEntryWithNoExplicitIdentityFallsBackToItsDescription() {
        let entry = RowDiffEntry(kind: .insert, keyDescription: "42", sourceRow: nil, targetRow: nil)

        XCTAssertEqual(entry.keyIdentity, "42")
    }
}

final class CompareSchemaMatchingTests: XCTestCase {
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
    func testTwoSchemasSharingATableNameAreComparedSeparately() {
        let report = StructureDiffEngine().compare(
            source: [snapshot("users", schema: "public"), snapshot("users", schema: "audit")],
            target: [snapshot("users", schema: "public")]
        )

        XCTAssertEqual(report.results.count, 2)
        XCTAssertEqual(report.count(of: .identical), 1)
        XCTAssertEqual(report.count(of: .onlyInSource), 1)
    }

    func testATargetOnlyTableInASecondSchemaIsReported() {
        let report = StructureDiffEngine().compare(
            source: [snapshot("users", schema: "public")],
            target: [snapshot("users", schema: "public"), snapshot("users", schema: "audit")]
        )

        XCTAssertEqual(report.count(of: .onlyInTarget), 1)
    }

    func testASchemalessEngineStillMatchesOnNameAlone() {
        let report = StructureDiffEngine().compare(
            source: [snapshot("users", schema: nil)],
            target: [snapshot("users", schema: nil)]
        )

        XCTAssertEqual(report.count(of: .identical), 1)
    }

    func testMatchKeyIgnoresSchemaWhenOnlyOneSideHasOne() {
        let options = StructureCompareOptions.default

        XCTAssertEqual(options.matchKey(name: "users", schema: nil), options.matchKey("users"))
        XCTAssertNotEqual(
            options.matchKey(name: "users", schema: "audit"),
            options.matchKey(name: "users", schema: "public")
        )
    }
}

final class CompareRunResultTests: XCTestCase {
    /// A commit that threw used to propagate past the whole run, so the result was discarded and
    /// the user got an error with no record of which statements had already executed.
    func testACommitFailureIsCarriedOnTheResultRatherThanReplacingIt() {
        let statement = SyncStatement(sql: "A;", objectName: "t", summary: "A")
        let result = CompareSyncRunResult(
            outcomes: [SyncStatementOutcome(id: statement.id, statement: statement, error: nil, wasSkipped: false)],
            rolledBack: false,
            cancelled: false,
            commitFailure: "deadlock detected"
        )

        XCTAssertEqual(result.executedCount, 1, "the per-statement record survives a failed commit")
        XCTAssertEqual(result.commitFailure, "deadlock detected")
    }

    func testASuccessfulRunCarriesNoCommitFailure() {
        let result = CompareSyncRunResult(outcomes: [], rolledBack: false, cancelled: false)

        XCTAssertNil(result.commitFailure)
    }
}

final class CompareDataPlanSchemaTests: XCTestCase {
    /// The target used to be read with the source's schema name, so a comparison of `audit.users`
    /// took `public.users`' columns while reading `audit.users`' rows.
    func testAPlanRemembersTheTargetsOwnSchema() {
        let plan = DataComparePlan(
            table: "users",
            schema: "public",
            targetSchema: "audit",
            columns: ["id"],
            keyColumns: ["id"],
            isEnabled: true
        )

        XCTAssertEqual(plan.schema, "public")
        XCTAssertEqual(plan.targetSchema, "audit")
    }

    func testAPlanWithNoTargetSchemaMirrorsTheSource() {
        let plan = DataComparePlan(
            table: "users", schema: "public", columns: ["id"], keyColumns: ["id"], isEnabled: true
        )

        XCTAssertEqual(plan.targetSchema, "public")
    }
}
