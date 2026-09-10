//
//  QueryPlanDiffTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Query plan comparison")
struct QueryPlanDiffTests {
    // MARK: - Verdict

    @Test("Two runs of an unchanged plan report no measurable change")
    func unchangedPlanReportsNoChange() {
        let plan = QueryPlanFixture.plan(root: QueryPlanFixture.node(operation: "Seq Scan", relation: "users"))
        let diff = QueryPlanDiff.compare(baseline: plan, current: plan)

        #expect(diff.verdict == .unchanged)
        #expect(diff.nodeChanges.isEmpty)
        #expect(!diff.hasChanges)
    }

    /// Timing jitter between two identical runs is not a regression, and reporting it as one makes
    /// the whole feature untrustworthy.
    @Test("A timing difference inside the noise band is not a regression")
    func smallTimingDifferenceIsNoise() {
        let baseline = QueryPlanFixture.plan(
            root: QueryPlanFixture.node(operation: "Seq Scan", relation: "users"),
            executionTime: 100
        )
        let current = QueryPlanFixture.plan(
            root: QueryPlanFixture.node(operation: "Seq Scan", relation: "users"),
            executionTime: 105
        )

        #expect(QueryPlanDiff.compare(baseline: baseline, current: current).verdict == .unchanged)
    }

    @Test("A real slowdown is reported as a multiple of the baseline")
    func slowdownIsReportedAsMultiple() throws {
        let baseline = QueryPlanFixture.plan(
            root: QueryPlanFixture.node(operation: "Seq Scan", relation: "users"),
            executionTime: 100
        )
        let current = QueryPlanFixture.plan(
            root: QueryPlanFixture.node(operation: "Seq Scan", relation: "users"),
            executionTime: 400
        )

        let verdict = QueryPlanDiff.compare(baseline: baseline, current: current).verdict
        let ratio = try #require({ if case .slower(let ratio) = verdict { return ratio } else { return nil } }())
        #expect(abs(ratio - 4) < 0.001)
        #expect(!verdict.headline.isEmpty)
    }

    @Test("A real speed-up is reported as faster")
    func speedUpIsReported() {
        let baseline = QueryPlanFixture.plan(
            root: QueryPlanFixture.node(operation: "Seq Scan", relation: "users"),
            executionTime: 400
        )
        let current = QueryPlanFixture.plan(
            root: QueryPlanFixture.node(operation: "Index Scan", relation: "users"),
            executionTime: 100
        )

        guard case .faster = QueryPlanDiff.compare(baseline: baseline, current: current).verdict else {
            Issue.record("expected a faster verdict")
            return
        }
    }

    @Test("A plan with no measured time falls back to shape and value verdicts")
    func fallsBackToShapeVerdict() {
        let baseline = QueryPlanFixture.plan(root: QueryPlanFixture.node(operation: "Seq Scan", relation: "users"))
        let current = QueryPlanFixture.plan(root: QueryPlanFixture.node(operation: "Index Scan", relation: "users"))

        #expect(QueryPlanDiff.compare(baseline: baseline, current: current).verdict == .shapeChanged)
    }

    // MARK: - Node matching

    /// The headline scenario: an index turns a sequential scan into an index scan.
    @Test("Replacing a scan reports one removal and one addition")
    func replacedScanIsOneRemovalAndOneAddition() {
        let baseline = QueryPlanFixture.plan(
            root: QueryPlanFixture.node(operation: "Limit", children: [
                QueryPlanFixture.node(operation: "Seq Scan", relation: "users"),
            ])
        )
        let current = QueryPlanFixture.plan(
            root: QueryPlanFixture.node(operation: "Limit", children: [
                QueryPlanFixture.node(operation: "Index Scan", relation: "users"),
            ])
        )

        let diff = QueryPlanDiff.compare(baseline: baseline, current: current)
        #expect(diff.nodeChanges.filter { $0.kind == .removed }.map(\.operation) == ["Seq Scan"])
        #expect(diff.nodeChanges.filter { $0.kind == .added }.map(\.operation) == ["Index Scan"])
    }

    /// A node inserted between two that stayed must not report the whole tail as rewritten. This is
    /// what a real sequence diff buys over pairing siblings by position.
    @Test("Inserting a sibling leaves the others matched")
    func insertedSiblingLeavesOthersMatched() {
        let baseline = QueryPlanFixture.plan(
            root: QueryPlanFixture.node(operation: "Append", children: [
                QueryPlanFixture.node(operation: "Seq Scan", relation: "a"),
                QueryPlanFixture.node(operation: "Seq Scan", relation: "c"),
            ])
        )
        let current = QueryPlanFixture.plan(
            root: QueryPlanFixture.node(operation: "Append", children: [
                QueryPlanFixture.node(operation: "Seq Scan", relation: "a"),
                QueryPlanFixture.node(operation: "Seq Scan", relation: "b"),
                QueryPlanFixture.node(operation: "Seq Scan", relation: "c"),
            ])
        )

        let diff = QueryPlanDiff.compare(baseline: baseline, current: current)
        #expect(diff.nodeChanges.count == 1)
        #expect(diff.nodeChanges[0].kind == .added)
        #expect(diff.nodeChanges[0].relation == "b")
    }

    @Test("Two siblings of the same shape keep distinct identities")
    func repeatedSiblingsKeepDistinctPaths() {
        let plan = QueryPlanFixture.plan(
            root: QueryPlanFixture.node(operation: "Append", children: [
                QueryPlanFixture.node(operation: "Seq Scan", relation: "a"),
                QueryPlanFixture.node(operation: "Seq Scan", relation: "a"),
            ])
        )
        let current = QueryPlanFixture.plan(
            root: QueryPlanFixture.node(operation: "Append", children: [
                QueryPlanFixture.node(operation: "Seq Scan", relation: "a"),
            ])
        )

        let diff = QueryPlanDiff.compare(baseline: plan, current: current)
        #expect(diff.nodeChanges.count == 1)
        #expect(diff.nodeChanges[0].kind == .removed)
        #expect(diff.nodeChanges[0].path.hasSuffix("#2"))
    }

    @Test("A whole removed subtree reports every node in it")
    func removedSubtreeReportsEveryNode() {
        let baseline = QueryPlanFixture.plan(
            root: QueryPlanFixture.node(operation: "Append", children: [
                QueryPlanFixture.node(operation: "Hash Join", children: [
                    QueryPlanFixture.node(operation: "Seq Scan", relation: "a"),
                    QueryPlanFixture.node(operation: "Seq Scan", relation: "b"),
                ]),
            ])
        )
        let current = QueryPlanFixture.plan(root: QueryPlanFixture.node(operation: "Append"))

        let diff = QueryPlanDiff.compare(baseline: baseline, current: current)
        #expect(diff.nodeChanges.count == 3)
        #expect(diff.nodeChanges.allSatisfy { $0.kind == .removed })
    }

    // MARK: - Field changes

    /// `QueryPlanLabels.visibleProperties` drops any value spelled `0` or `false`, which is right
    /// for the node inspector and wrong here: a filter that stopped discarding rows is exactly the
    /// improvement the reader came for, and hiding the zero reported it as the property vanishing.
    @Test("A property that fell to zero reads as a value change, not a removal")
    func propertyFallingToZeroIsNotARemoval() throws {
        let baseline = QueryPlanFixture.plan(
            root: QueryPlanFixture.node(
                operation: "Seq Scan",
                relation: "users",
                properties: ["Rows Removed by Filter": "1000"]
            )
        )
        let current = QueryPlanFixture.plan(
            root: QueryPlanFixture.node(
                operation: "Seq Scan",
                relation: "users",
                properties: ["Rows Removed by Filter": "0"]
            )
        )

        let diff = QueryPlanDiff.compare(baseline: baseline, current: current)
        let change = try #require(diff.nodeChanges.first)
        #expect(change.kind == .changed)
        let field = try #require(change.fieldChanges.first { $0.field == .property("Rows Removed by Filter") })
        #expect(field.before == .text("1000"))
        #expect(field.after == .text("0"))
    }

    @Test("A metric change carries numbers rather than rendered strings")
    func metricChangeCarriesNumbers() throws {
        let baseline = QueryPlanFixture.plan(
            root: QueryPlanFixture.node(operation: "Seq Scan", relation: "users", estimatedTotalCost: 52_000_000)
        )
        let current = QueryPlanFixture.plan(
            root: QueryPlanFixture.node(operation: "Seq Scan", relation: "users", estimatedTotalCost: 61_000_000)
        )

        let change = try #require(QueryPlanDiff.compare(baseline: baseline, current: current).nodeChanges.first)
        let field = try #require(change.fieldChanges.first { $0.field == .metric(.estimatedTotalCost) })
        #expect(field.before == .number(52_000_000))
        #expect(field.after == .number(61_000_000))
        #expect(field.delta == 9_000_000)
    }

    @Test("Noise properties stay out of the comparison")
    func hiddenPropertiesAreIgnored() {
        let baseline = QueryPlanFixture.plan(
            root: QueryPlanFixture.node(operation: "Seq Scan", relation: "users", properties: ["Parallel Aware": "false"])
        )
        let current = QueryPlanFixture.plan(
            root: QueryPlanFixture.node(operation: "Seq Scan", relation: "users", properties: ["Parallel Aware": "true"])
        )

        #expect(QueryPlanDiff.compare(baseline: baseline, current: current).nodeChanges.isEmpty)
    }

    @Test("The summary reports plan-wide metrics even when nothing changed")
    func summaryAlwaysReportsEveryMetric() {
        let plan = QueryPlanFixture.plan(root: QueryPlanFixture.node(operation: "Seq Scan", relation: "users"))
        let diff = QueryPlanDiff.compare(baseline: plan, current: plan)

        #expect(diff.summary.count == QueryPlanSummaryMetric.allCases.count)
        #expect(diff.summary.allSatisfy { !$0.hasChange })
    }
}

enum QueryPlanFixture {
    static func node(
        operation: String,
        relation: String? = nil,
        alias: String? = nil,
        estimatedTotalCost: Double? = nil,
        properties: [String: String] = [:],
        children: [QueryPlanNode] = []
    ) -> QueryPlanNode {
        QueryPlanNode(
            operation: operation,
            relation: relation,
            schema: nil,
            alias: alias,
            estimatedStartupCost: nil,
            estimatedTotalCost: estimatedTotalCost,
            estimatedRows: nil,
            estimatedWidth: nil,
            actualStartupTime: nil,
            actualTotalTime: nil,
            actualRows: nil,
            actualLoops: nil,
            properties: properties,
            children: children
        )
    }

    static func plan(
        root: QueryPlanNode,
        planningTime: Double? = nil,
        executionTime: Double? = nil
    ) -> QueryPlan {
        QueryPlan(
            rootNode: root,
            planningTime: planningTime,
            executionTime: executionTime,
            rawText: root.operation
        )
    }
}
