//
//  QueryPlanMetricIndexTests.swift
//  TableProTests
//
//  What the plan outline's magnitude column draws: a length against the largest node, a colour
//  against the plan, and nothing at all when the plan reports nothing.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Query Plan Metric Index")
struct QueryPlanMetricIndexTests {
    private func node(
        _ operation: String,
        cost: Double? = nil,
        rows: Int? = nil,
        actualTime: Double? = nil,
        actualRows: Int? = nil,
        loops: Int? = nil,
        properties: [String: String] = [:],
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
            actualRows: actualRows,
            actualLoops: loops,
            properties: properties,
            children: children
        )
    }

    private func plan(_ root: QueryPlanNode) -> QueryPlan {
        QueryPlan(rootNode: root, planningTime: nil, executionTime: nil, rawText: "")
    }

    // MARK: - Scale

    @Test("The largest node fills the track and the rest are drawn against it")
    func scalesAgainstTheLargestNode() throws {
        let small = node("Hash", cost: 10)
        let large = node("Seq Scan", cost: 90)
        let root = node("Hash Join", cost: 200, children: [small, large])
        let index = try #require(QueryPlanMetricIndex(metric: .selfCost, plan: plan(root)))

        // Root self cost is 200 - 100 = 100, which is the largest.
        #expect(index.fraction(for: root) == 1)
        #expect(index.fraction(for: large) == 0.9)
        #expect(index.fraction(for: small) == 0.1)
    }

    @Test("Shares of an additive metric add up to the whole plan")
    func additiveSharesSumToOne() throws {
        let a = node("Seq Scan", cost: 60)
        let b = node("Hash", cost: 20)
        let root = node("Hash Join", cost: 100, children: [a, b])
        let index = try #require(QueryPlanMetricIndex(metric: .selfCost, plan: plan(root)))

        let total = [root, a, b].compactMap { index.emphasis(for: $0) }.reduce(0, +)
        #expect(abs(total - 1) < 0.0001)
        #expect(index.emphasis(for: a) == 0.6)
    }

    @Test("A row count is weighed against the largest node, because rows do not add up")
    func rowMetricUsesTheLargestNode() throws {
        let leaf = node("Seq Scan", rows: 500)
        let root = node("Aggregate", rows: 500, children: [leaf])
        let index = try #require(QueryPlanMetricIndex(metric: .estimatedRows, plan: plan(root)))

        // A share would report 0.5 each, claiming the plan produced 1000 rows.
        #expect(index.emphasis(for: leaf) == 1)
        #expect(index.emphasis(for: root) == 1)
        #expect(QueryPlanBarMetric.estimatedRows.isAdditive == false)

        // And because every node here is the maximum, a severity would paint the whole column red.
        #expect(index.severity(for: leaf) == nil)
        #expect(index.severity(for: root) == nil)
    }

    @Test("An additive metric still carries a severity")
    func gradesAdditiveMetrics() throws {
        let hot = node("Seq Scan", cost: 90)
        let cool = node("Hash", cost: 4)
        let root = node("Hash Join", cost: 100, children: [hot, cool])
        let index = try #require(QueryPlanMetricIndex(metric: .selfCost, plan: plan(root)))

        #expect(index.severity(for: hot) == .critical)
        #expect(index.severity(for: cool) == .low)
    }

    @Test("A node that reports nothing draws nothing, and a zero is not a missing value")
    func distinguishesAbsentFromZero() throws {
        let measured = node("Sort", cost: 40)
        let unmeasured = node("Result")
        let root = node("Limit", cost: 40, children: [measured, unmeasured])
        let index = try #require(QueryPlanMetricIndex(metric: .selfCost, plan: plan(root)))

        #expect(index.value(for: unmeasured) == nil)
        #expect(index.fraction(for: unmeasured) == nil)
        // The root's own cost equals its child's, so it did no work of its own.
        #expect(index.value(for: root) == 0)
        #expect(index.fraction(for: root) == 0)
    }

    @Test("A parent priced below its children clamps rather than going negative")
    func clampsAnInvertedParent() throws {
        let child = node("Seq Scan", cost: 900)
        let root = node("Limit", cost: 10, children: [child])
        let index = try #require(QueryPlanMetricIndex(metric: .selfCost, plan: plan(root)))

        #expect(index.value(for: root) == 0)
        #expect(index.fraction(for: child) == 1)
    }

    @Test("Every fraction and emphasis stays inside the track")
    func staysWithinBounds() throws {
        let child = node("Seq Scan", cost: 7_876_009)
        let root = node("Limit", cost: 1, children: [child])
        let index = try #require(QueryPlanMetricIndex(metric: .selfCost, plan: plan(root)))

        for node in [root, child] {
            let fraction = try #require(index.fraction(for: node))
            let emphasis = try #require(index.emphasis(for: node))
            #expect((0 ... 1).contains(fraction))
            #expect((0 ... 1).contains(emphasis))
        }
    }

    // MARK: - Availability

    @Test("A plan that reports nothing offers no metric and builds no index")
    func offersNothingForAMetriclessPlan() {
        let root = node("SCAN Track", children: [node("USE TEMP B-TREE FOR ORDER BY")])
        let costless = plan(root)

        #expect(QueryPlanMetricIndex.availableMetrics(in: costless).isEmpty)
        #expect(QueryPlanMetricIndex(metric: .selfCost, plan: costless) == nil)
        #expect(QueryPlanMetricIndex.defaultMetric(among: []) == nil)
    }

    @Test("Availability follows the plan, not the engine")
    func resolvesAvailabilityPerPlan() {
        let estimated = plan(node("Seq Scan", cost: 10, rows: 100))
        #expect(QueryPlanMetricIndex.availableMetrics(in: estimated) == [.selfCost, .estimatedRows])

        let analyzed = plan(node("Seq Scan", cost: 10, rows: 100, actualTime: 2, actualRows: 90, loops: 1))
        #expect(
            QueryPlanMetricIndex.availableMetrics(in: analyzed)
                == [.selfCost, .selfTime, .estimatedRows, .actualRows]
        )
    }

    @Test("A plan with only row counts still charts them")
    func chartsRowsWithoutACost() {
        let cockroach = plan(node("scan", rows: 1_000, actualRows: 950))
        #expect(QueryPlanMetricIndex.availableMetrics(in: cockroach) == [.estimatedRows, .actualRows])
        #expect(QueryPlanMetricIndex.defaultMetric(among: [.estimatedRows, .actualRows]) == .estimatedRows)
    }

    @Test("Measurement is preferred to estimate when the plan carries both")
    func prefersMeasuredTime() {
        #expect(QueryPlanMetricIndex.defaultMetric(among: [.selfCost, .selfTime]) == .selfTime)
        #expect(QueryPlanMetricIndex.defaultMetric(among: [.selfCost, .estimatedRows]) == .selfCost)
    }

    // MARK: - Columns

    @Test("A column with nothing to show is not shown")
    func hidesColumnsThePlanCannotFill() {
        let sqlite = plan(node("SCAN Track"))
        let cockroach = plan(node("scan", rows: 1_000, actualRows: 950))

        #expect(QueryPlanOutlineColumn.cost.hasContent(in: sqlite, metrics: nil) == false)
        #expect(QueryPlanOutlineColumn.rows.hasContent(in: sqlite, metrics: nil) == false)
        #expect(QueryPlanOutlineColumn.actualTime.hasContent(in: sqlite, metrics: nil) == false)
        #expect(QueryPlanOutlineColumn.operation.hasContent(in: sqlite, metrics: nil))

        // CockroachDB reports rows and nothing else, which is the mixed case.
        #expect(QueryPlanOutlineColumn.rows.hasContent(in: cockroach, metrics: nil))
        #expect(QueryPlanOutlineColumn.cost.hasContent(in: cockroach, metrics: nil) == false)
        #expect(QueryPlanOutlineColumn.actualTime.hasContent(in: cockroach, metrics: nil) == false)
    }

    @Test("The magnitude column is titled by the metric it charts")
    func titlesTheColumnByItsMetric() {
        #expect(QueryPlanOutlineColumn.magnitude.title(metric: .selfTime) == QueryPlanBarMetric.selfTime.title)
        #expect(QueryPlanOutlineColumn.magnitude.title(metric: nil) == QueryPlanLabels.magnitude)
        #expect(QueryPlanOutlineColumn.cost.title(metric: .selfTime) == QueryPlanLabels.cost)
    }

    // MARK: - Presentation

    @Test("A row metric is not described as a share of anything")
    func phrasesEmphasisPerMetric() {
        #expect(QueryPlanBarMetric.selfCost.emphasisDescription("40%").contains("plan"))
        #expect(QueryPlanBarMetric.actualRows.emphasisDescription("40%").contains("largest"))
    }

    /// Asserted against the locale's own formatting rather than against English digits. The
    /// separators move with the locale (this machine is `en_VN`, which writes 7,9M for 7.9M), so
    /// hardcoding them tests the region, not the code.
    @Test("A long cost is abbreviated so the number never crowds out the bar")
    func abbreviatesLargeValues() {
        let long = QueryPlanValueFormatter.compact(7_876_009, unit: .cost)
        #expect(long == 7_876_009.0.formatted(.number.notation(.compactName).precision(.fractionLength(0 ... 1))))
        #expect(long.count <= 6)
        #expect(long != QueryPlanValueFormatter.string(7_876_009, unit: .cost))

        let thousands = QueryPlanValueFormatter.compact(49_475, unit: .count)
        #expect(thousands.count <= 6)
        #expect(thousands != QueryPlanValueFormatter.string(49_475, unit: .count))

        // The default metric is a duration, so its label is the one most likely to be cut off.
        // Measured: 12345.678ms spells "12.345,678 ms" in full and "12,35s" compact.
        for milliseconds in [12_345.678, 125_000.0, 1_000.0] {
            let compact = QueryPlanValueFormatter.compact(milliseconds, unit: .milliseconds)
            #expect(compact.count <= 8)
            #expect(compact.count < QueryPlanValueFormatter.string(milliseconds, unit: .milliseconds).count)
        }

        // Below a second the value keeps its own unit rather than being rounded to 0s.
        #expect(QueryPlanValueFormatter.compact(21.5, unit: .milliseconds).count <= 8)
        #expect(QueryPlanValueFormatter.compact(0.019, unit: .milliseconds).contains("0"))

        // Below the threshold the value is spelled out in full, so a small cost keeps its digits.
        #expect(QueryPlanValueFormatter.compact(806, unit: .cost) == QueryPlanValueFormatter.string(806, unit: .cost))
        #expect(QueryPlanValueFormatter.compact(0.64, unit: .cost) == QueryPlanValueFormatter.string(0.64, unit: .cost))
    }
}
