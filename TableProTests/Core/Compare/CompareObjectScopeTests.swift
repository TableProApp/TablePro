//
//  CompareObjectScopeTests.swift
//  TableProTests
//
//  What the comparison used to get wrong before an object had a kind: `fetchTables` reports views
//  alongside tables, so a view reached the table paths and produced CREATE TABLE for a view.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct CompareTableKindClassifierTests {
    private func table(_ type: String) -> PluginTableInfo {
        PluginTableInfo(name: "orders", type: type, schema: "public", comment: nil)
    }

    @Test
    func viewsAreRecognisedHoweverTheEngineSpellsThem() {
        for spelling in ["VIEW", "view", "SYSTEM VIEW", "BASE VIEW"] {
            #expect(CompareTableKindClassifier.kind(of: table(spelling)) == .view, Comment(rawValue: spelling))
        }
    }

    @Test
    func materializedViewsAreTheirOwnKind() {
        for spelling in ["MATERIALIZED VIEW", "MATERIALIZED_VIEW", "materialized view"] {
            #expect(CompareTableKindClassifier.kind(of: table(spelling)) == .materializedView, Comment(rawValue: spelling))
        }
    }

    /// PostgreSQL reports PARTITIONED TABLE for an ordinary, directly queryable table. Matching the
    /// literal string TABLE would have silently dropped it from every comparison, which is why the
    /// rule is subtractive.
    @Test
    func partitionedAndForeignTablesStillCompareAsTables() {
        for spelling in ["TABLE", "BASE TABLE", "PARTITIONED TABLE", "FOREIGN TABLE", "LOCAL TEMPORARY"] {
            #expect(CompareTableKindClassifier.kind(of: table(spelling)) == .table, Comment(rawValue: spelling))
        }
    }

    @Test
    func aForeignTableIsFlaggedSeparatelyFromItsKind() {
        #expect(CompareTableKindClassifier.isForeign(table("FOREIGN TABLE")))
        #expect(!(CompareTableKindClassifier.isForeign(table("BASE TABLE"))))
    }

    @Test
    func onlyATableCarriesRows() {
        #expect(CompareObjectKind.table.carriesRows)
        for kind in CompareObjectKind.allCases where kind != .table {
            #expect(!kind.carriesRows, "\(kind.rawValue) holds no rows a data compare can walk")
        }
    }
}

struct DataComparePlanColumnTests {
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
    @Test
    func generatedColumnsAreReadButNotWritten() {
        let plan = plan(generated: ["line_total"])

        #expect(plan.columnNames == ["id", "total", "line_total"])
        #expect(plan.writeColumns == ["id", "total"])
    }

    /// An identity column the target always generates takes its value on insert only through the
    /// engine's override, and never through an UPDATE.
    @Test
    func anAlwaysIdentityColumnIsInsertedButNeverUpdated() {
        let plan = plan(generated: [], identity: ["id": .always])

        #expect(plan.writeColumns == ["id", "total", "line_total"])
        #expect(plan.updatableColumns == ["total", "line_total"])
        #expect(plan.insertsIntoIdentityColumn)
    }

    @Test
    func aByDefaultIdentityColumnNeedsNoOverride() {
        #expect(!(plan(generated: [], identity: ["id": .byDefault]).insertsIntoIdentityColumn))
    }

    @Test
    func excludedColumnsAreLeftOutOfTheComparisonOnlyForTheirOwnTable() {
        var excluded = plan(generated: [])
        excluded.scope.setExcluded(true, column: "TOTAL")

        #expect(excluded.comparedColumns == ["line_total"])
        #expect(plan(generated: []).comparedColumns == ["total", "line_total"])
        #expect(excluded.writeColumns == ["id", "total", "line_total"])
    }

    @Test
    func aTableWhoseSharedColumnsAreAllGeneratedIsNotComparable() {
        let allGenerated = plan(generated: ["id", "total", "line_total"])

        #expect(DataComparePlan.unavailableReason(for: allGenerated) != nil)
    }

    @Test
    func keyDescriptorsCarryOnlyTheKeyColumns() {
        #expect(plan(generated: []).keyDescriptors.map { $0.name } == ["id"])
    }

    @Test
    func aTableWithNoKeyIsNotComparable() {
        #expect(DataComparePlan.unavailableReason(for: plan(generated: [], keys: [])) != nil)
    }

    @Test
    func aKeyMissingFromTheSharedColumnsIsNotComparable() {
        #expect(DataComparePlan.unavailableReason(for: plan(generated: [], keys: ["tenant_id"])) != nil)
    }
}
