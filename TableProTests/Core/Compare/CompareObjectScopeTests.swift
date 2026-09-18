//
//  CompareObjectScopeTests.swift
//  TableProTests
//
//  What the comparison used to get wrong before an object had a kind: `fetchTables` reports views
//  alongside tables, so a view reached the table paths and produced CREATE TABLE for a view.
//

@testable import TablePro
import TableProPluginKit
import XCTest

final class CompareTableKindClassifierTests: XCTestCase {
    private func table(_ type: String) -> PluginTableInfo {
        PluginTableInfo(name: "orders", type: type, schema: "public", comment: nil)
    }

    func testViewsAreRecognisedHoweverTheEngineSpellsThem() {
        for spelling in ["VIEW", "view", "SYSTEM VIEW", "BASE VIEW"] {
            XCTAssertEqual(CompareTableKindClassifier.kind(of: table(spelling)), .view, spelling)
        }
    }

    func testMaterializedViewsAreTheirOwnKind() {
        for spelling in ["MATERIALIZED VIEW", "MATERIALIZED_VIEW", "materialized view"] {
            XCTAssertEqual(CompareTableKindClassifier.kind(of: table(spelling)), .materializedView, spelling)
        }
    }

    /// PostgreSQL reports PARTITIONED TABLE for an ordinary, directly queryable table. Matching the
    /// literal string TABLE would have silently dropped it from every comparison, which is why the
    /// rule is subtractive.
    func testPartitionedAndForeignTablesStillCompareAsTables() {
        for spelling in ["TABLE", "BASE TABLE", "PARTITIONED TABLE", "FOREIGN TABLE", "LOCAL TEMPORARY"] {
            XCTAssertEqual(CompareTableKindClassifier.kind(of: table(spelling)), .table, spelling)
        }
    }

    func testAForeignTableIsFlaggedSeparatelyFromItsKind() {
        XCTAssertTrue(CompareTableKindClassifier.isForeign(table("FOREIGN TABLE")))
        XCTAssertFalse(CompareTableKindClassifier.isForeign(table("BASE TABLE")))
    }

    func testOnlyATableCarriesRows() {
        XCTAssertTrue(CompareObjectKind.table.carriesRows)
        for kind in CompareObjectKind.allCases where kind != .table {
            XCTAssertFalse(kind.carriesRows, "\(kind.rawValue) holds no rows a data compare can walk")
        }
    }
}

final class DataComparePlanColumnTests: XCTestCase {
    private func plan(
        generated: Set<String>,
        keys: [String] = ["id"],
        identity: [String: IdentityKind] = [:]
    ) -> DataComparePlan {
        let types = ["id": "bigint", "total": "numeric", "line_total": "numeric"]
        return DataComparePlan(
            table: "orders",
            schema: "public",
            columns: ["id", "total", "line_total"].map { name in
                CompareColumn(
                    name: name,
                    sourceType: types[name],
                    targetType: types[name],
                    isGeneratedOnTarget: generated.contains(name),
                    targetIdentity: identity[name]
                )
            },
            scope: DataTableScope(keyColumns: keys),
            isEnabled: true
        )
    }

    /// MySQL rejects an explicit value for a generated column outright and PostgreSQL rejects it
    /// for a stored one, so it is read and compared but never written.
    func testGeneratedColumnsAreReadButNotWritten() {
        let plan = plan(generated: ["line_total"])

        XCTAssertEqual(plan.columnNames, ["id", "total", "line_total"])
        XCTAssertEqual(plan.writeColumns, ["id", "total"])
    }

    /// An identity column the target always generates takes its value on insert only through the
    /// engine's override, and never through an UPDATE.
    func testAnAlwaysIdentityColumnIsInsertedButNeverUpdated() {
        let plan = plan(generated: [], identity: ["id": .always])

        XCTAssertEqual(plan.writeColumns, ["id", "total", "line_total"])
        XCTAssertEqual(plan.updatableColumns, ["total", "line_total"])
        XCTAssertTrue(plan.insertsIntoIdentityColumn)
    }

    func testAByDefaultIdentityColumnNeedsNoOverride() {
        XCTAssertFalse(plan(generated: [], identity: ["id": .byDefault]).insertsIntoIdentityColumn)
    }

    func testExcludedColumnsAreLeftOutOfTheComparisonOnlyForTheirOwnTable() {
        var excluded = plan(generated: [])
        excluded.scope.setExcluded(true, column: "TOTAL")

        XCTAssertEqual(excluded.comparedColumns, ["line_total"])
        XCTAssertEqual(plan(generated: []).comparedColumns, ["total", "line_total"])
        XCTAssertEqual(excluded.writeColumns, ["id", "total", "line_total"])
    }

    func testATableWhoseSharedColumnsAreAllGeneratedIsNotComparable() {
        let allGenerated = plan(generated: ["id", "total", "line_total"])

        XCTAssertNotNil(DataComparePlan.unavailableReason(for: allGenerated))
    }

    func testKeyDescriptorsCarryOnlyTheKeyColumns() {
        XCTAssertEqual(plan(generated: []).keyDescriptors.map { $0.name }, ["id"])
    }

    func testATableWithNoKeyIsNotComparable() {
        XCTAssertNotNil(DataComparePlan.unavailableReason(for: plan(generated: [], keys: [])))
    }

    func testAKeyMissingFromTheSharedColumnsIsNotComparable() {
        XCTAssertNotNil(DataComparePlan.unavailableReason(for: plan(generated: [], keys: ["tenant_id"])))
    }
}
