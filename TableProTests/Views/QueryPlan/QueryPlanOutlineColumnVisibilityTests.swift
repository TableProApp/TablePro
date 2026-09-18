//
//  QueryPlanOutlineColumnVisibilityTests.swift
//  TableProTests
//
//  A column the plan cannot fill is hidden, and one it can is shown again.
//
//  Asserted against the coordinator's real `NSTableColumn`s rather than through XCUITest: the CI
//  runner does not publish this outline's headers to the accessibility tree the way a local Mac
//  does, so a UI test reading the column set was testing the tree rather than the rule.
//

import AppKit
@testable import TablePro
import Testing

@Suite("Query Plan Outline Column Visibility")
@MainActor
struct QueryPlanOutlineColumnVisibilityTests {
    private func node(
        _ operation: String,
        cost: Double? = nil,
        rows: Int? = nil,
        actualTime: Double? = nil,
        loops: Int? = nil,
        children: [QueryPlanNode] = []
    ) -> QueryPlanNode {
        QueryPlanNode(
            operation: operation,
            relation: nil, schema: nil, alias: nil,
            estimatedStartupCost: nil,
            estimatedTotalCost: cost,
            estimatedRows: rows,
            estimatedWidth: nil,
            actualStartupTime: nil,
            actualTotalTime: actualTime,
            actualRows: nil,
            actualLoops: loops,
            properties: [:],
            children: children
        )
    }

    private func plan(_ root: QueryPlanNode) -> QueryPlan {
        var plan = QueryPlan(rootNode: root, planningTime: nil, executionTime: nil, rawText: "")
        plan.computeCostFractions()
        return plan
    }

    /// The outline is built the way `QueryPlanOutlineView.makeNSView` builds it, minus the window:
    /// the coordinator only needs its columns and a view to hold them.
    private func makeOutline() -> (QueryPlanOutlineCoordinator, NSOutlineView) {
        let outlineView = NSOutlineView()
        let coordinator = QueryPlanOutlineCoordinator()
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.configureColumns(on: outlineView)
        outlineView.outlineTableColumn = outlineView.tableColumns.first
        coordinator.outlineView = outlineView
        return (coordinator, outlineView)
    }

    private func hidden(_ outlineView: NSOutlineView) -> Set<String> {
        Set(outlineView.tableColumns.filter(\.isHidden).map(\.identifier.rawValue))
    }

    @Test("Every column is built, in the declared order")
    func buildsEveryColumn() {
        let (_, outlineView) = makeOutline()

        #expect(
            outlineView.tableColumns.map(\.identifier.rawValue)
                == QueryPlanOutlineColumn.allCases.map(\.rawValue)
        )
    }

    @Test("A plan that reports nothing shows the operation column alone")
    func hidesEveryEmptyColumn() {
        let (coordinator, outlineView) = makeOutline()
        let sqlite = plan(node("SCAN Track", children: [node("USE TEMP B-TREE FOR ORDER BY")]))

        coordinator.update(plan: sqlite, metric: nil, differentiateWithoutColor: false)

        #expect(hidden(outlineView) == ["magnitude", "cost", "rows", "actualTime"])
    }

    /// CockroachDB reports row counts and never a cost, which is the only format that exercises
    /// mixed per-column availability rather than all-or-nothing.
    @Test("A plan that reports only rows keeps the rows column and drops the rest")
    func keepsTheColumnsAPartialPlanFills() {
        let (coordinator, outlineView) = makeOutline()
        let cockroach = plan(node("scan", rows: 1_000))
        let metric = QueryPlanMetricIndex.defaultMetric(
            among: QueryPlanMetricIndex.availableMetrics(in: cockroach)
        )

        coordinator.update(plan: cockroach, metric: metric, differentiateWithoutColor: false)

        #expect(hidden(outlineView) == ["cost", "actualTime"])
    }

    @Test("A measured plan shows every column")
    func showsEveryColumnForAMeasuredPlan() {
        let (coordinator, outlineView) = makeOutline()
        let analyzed = plan(node("Seq Scan", cost: 90, rows: 500, actualTime: 12, loops: 1))
        let metric = QueryPlanMetricIndex.defaultMetric(
            among: QueryPlanMetricIndex.availableMetrics(in: analyzed)
        )

        coordinator.update(plan: analyzed, metric: metric, differentiateWithoutColor: false)

        #expect(hidden(outlineView).isEmpty)
    }

    /// `isHidden` is persisted by the column autosave, so a column hidden for one plan and never
    /// explicitly shown again would stay hidden for every plan after it.
    @Test("A column hidden for one plan comes back for the next")
    func unhidesAColumnTheNextPlanFills() {
        let (coordinator, outlineView) = makeOutline()

        coordinator.update(plan: plan(node("SCAN Track")), metric: nil, differentiateWithoutColor: false)
        #expect(hidden(outlineView).contains("cost"))

        let analyzed = plan(node("Seq Scan", cost: 90, rows: 500, actualTime: 12, loops: 1))
        let metric = QueryPlanMetricIndex.defaultMetric(
            among: QueryPlanMetricIndex.availableMetrics(in: analyzed)
        )
        coordinator.update(plan: analyzed, metric: metric, differentiateWithoutColor: false)

        #expect(hidden(outlineView).isEmpty)
    }

    @Test("The magnitude column is titled by the metric it charts")
    func titlesTheMagnitudeColumn() {
        let (coordinator, outlineView) = makeOutline()
        let analyzed = plan(node("Seq Scan", cost: 90, rows: 500, actualTime: 12, loops: 1))

        coordinator.update(plan: analyzed, metric: .selfTime, differentiateWithoutColor: false)

        let magnitude = outlineView.tableColumns.first { $0.identifier.rawValue == "magnitude" }
        #expect(magnitude?.title == QueryPlanBarMetric.selfTime.title)
    }
}
