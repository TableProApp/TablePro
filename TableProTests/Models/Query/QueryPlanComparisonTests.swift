//
//  QueryPlanComparisonTests.swift
//  TableProTests
//
//  Tests for deterministic older-to-current query plan comparison.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Query Plan Comparison")
struct QueryPlanComparisonTests {
    private func node(
        _ operation: String,
        relation: String? = nil,
        schema: String? = nil,
        alias: String? = nil,
        totalCost: Double? = nil,
        rows: Int? = nil,
        properties: [String: String] = [:],
        children: [QueryPlanNode] = []
    ) -> QueryPlanNode {
        QueryPlanNode(
            operation: operation,
            relation: relation,
            schema: schema,
            alias: alias,
            estimatedStartupCost: nil,
            estimatedTotalCost: totalCost,
            estimatedRows: rows,
            estimatedWidth: nil,
            actualStartupTime: nil,
            actualTotalTime: nil,
            actualRows: nil,
            actualLoops: nil,
            properties: properties,
            children: children
        )
    }

    private func plan(
        root: QueryPlanNode,
        planningTime: Double? = nil,
        executionTime: Double? = nil
    ) -> QueryPlan {
        QueryPlan(
            rootNode: root,
            planningTime: planningTime,
            executionTime: executionTime,
            rawText: ""
        )
    }

    @Test("Fresh UUIDs do not make identical trees different")
    func ignoresNodeIDs() {
        let older = plan(root: node("Nested Loop", children: [
            node("Seq Scan", relation: "users", schema: "public", alias: "u", totalCost: 3),
        ]))
        let current = plan(root: node("Nested Loop", children: [
            node("Seq Scan", relation: "users", schema: "public", alias: "u", totalCost: 3),
        ]))

        #expect(older.rootNode.id != current.rootNode.id)
        #expect(!QueryPlanComparison(previous: older, current: current).hasChanges)
    }

    @Test("Metric-only changes modify the matching node")
    func reportsMetricChange() throws {
        let comparison = QueryPlanComparison(
            previous: plan(root: node("Seq Scan", relation: "users", totalCost: 10, rows: 100)),
            current: plan(root: node("Seq Scan", relation: "users", totalCost: 12, rows: 80))
        )

        let change = try #require(comparison.nodeChanges.first)
        #expect(comparison.nodeChanges.count == 1)
        #expect(change.kind == .modified)
        #expect(change.operation == "Seq Scan")
        #expect(change.relation == "users")
        #expect(
            change.valueChanges.map(\.name) == [
                String(localized: "Estimated Rows"),
                String(localized: "Estimated Total Cost"),
            ]
        )
        #expect(comparison.summary.rootEstimatedTotalCost.delta == 2)
        #expect(comparison.summary.rootEstimatedRows.delta == -20)
    }

    @Test("A scan added and another removed keep older-to-current direction")
    func reportsAddedAndRemovedScan() {
        let older = plan(root: node("Append", children: [
            node("Seq Scan", relation: "users"),
        ]))
        let current = plan(root: node("Append", children: [
            node("Index Scan", relation: "orders", properties: ["Index Name": "orders_pkey"]),
        ]))
        let changes = QueryPlanComparison(previous: older, current: current).nodeChanges

        #expect(changes.count == 2)
        #expect(changes.contains { $0.kind == .removed && $0.relation == "users" })
        #expect(changes.contains { $0.kind == .added && $0.relation == "orders" })
    }

    @Test("An operation change is a removal plus an addition")
    func reportsOperationReplacement() {
        let comparison = QueryPlanComparison(
            previous: plan(root: node("Seq Scan", relation: "users")),
            current: plan(root: node("Index Scan", relation: "users", properties: ["Index Name": "users_pkey"]))
        )

        #expect(comparison.nodeChanges.map(\.kind).sorted(by: { $0.rawValue < $1.rawValue }) == [.added, .removed])
        #expect(comparison.nodeChanges.allSatisfy { $0.kind != .modified })
    }

    @Test("A changed identifying property replaces the node")
    func usesVisibleIdentifyingProperties() {
        let comparison = QueryPlanComparison(
            previous: plan(root: node("Index Scan", relation: "users", properties: [
                "Index Name": "users_email_idx",
            ])),
            current: plan(root: node("Index Scan", relation: "users", properties: [
                "Index Name": "users_pkey",
            ]))
        )

        #expect(comparison.nodeChanges.count == 2)
        #expect(Set(comparison.nodeChanges.map(\.kind)) == [.added, .removed])
    }

    @Test("Duplicate siblings pair by occurrence order")
    func pairsDuplicateSiblingsByOccurrence() {
        let older = plan(root: node("Append", children: [
            node("Seq Scan", relation: "events", totalCost: 1),
            node("Seq Scan", relation: "events", totalCost: 2),
        ]))
        let current = plan(root: node("Append", children: [
            node("Seq Scan", relation: "events", totalCost: 10),
            node("Seq Scan", relation: "events", totalCost: 20),
        ]))
        let changes = QueryPlanComparison(previous: older, current: current).nodeChanges

        #expect(changes.count == 2)
        #expect(changes.allSatisfy { $0.kind == .modified })
        #expect(changes.map(\.semanticPathID).contains { $0.hasSuffix("#1") })
        #expect(changes.map(\.semanticPathID).contains { $0.hasSuffix("#2") })
        #expect(changes[0].valueChanges.first?.previousValue == "1.0")
        #expect(changes[0].valueChanges.first?.currentValue == "10.0")
        #expect(changes[1].valueChanges.first?.previousValue == "2.0")
        #expect(changes[1].valueChanges.first?.currentValue == "20.0")
    }

    @Test("Reordering nested-loop inputs reports a deterministic move")
    func reportsNestedLoopInputReorder() {
        let users = node("Table scan", relation: "users", totalCost: 1)
        let orders = node("Index lookup", relation: "orders", totalCost: 2, properties: [
            "Index Name": "user_id_idx",
        ])
        let older = plan(root: node("Nested loop inner join", children: [users, orders]))
        let current = plan(root: node("Nested loop inner join", children: [orders, users]))
        let first = QueryPlanComparison(previous: older, current: current)
        let second = QueryPlanComparison(previous: older, current: current)

        #expect(first.hasChanges)
        #expect(first.nodeChanges.count == 2)
        #expect(first.nodeChanges.map(\.kind) == [.removed, .added])
        #expect(first.nodeChanges.allSatisfy { $0.relation == "users" })
        #expect(first.nodeChanges == second.nodeChanges)
        #expect(Set(first.nodeChanges.map(\.id)).count == first.nodeChanges.count)
    }

    @Test("Duplicate siblings retain occurrence paths when one is removed")
    func keepsDuplicateOccurrencePaths() throws {
        let older = plan(root: node("Append", children: [
            node("Seq Scan", relation: "events"),
            node("Seq Scan", relation: "events"),
        ]))
        let current = plan(root: node("Append", children: [
            node("Seq Scan", relation: "events"),
        ]))
        let change = try #require(
            QueryPlanComparison(previous: older, current: current).nodeChanges.first
        )

        #expect(change.kind == .removed)
        #expect(change.semanticPathID.hasSuffix("#2"))
    }

    @Test("Wide sibling plans use the bounded ordered fallback")
    func boundsWidePlanMatching() {
        let width = Int(Double(QueryPlanComparison.maximumLCSCellCount).squareRoot()) + 1
        #expect(width * width > QueryPlanComparison.maximumLCSCellCount)
        #expect(QueryPlanComparison.usesLinearSiblingMatcher(
            previousCount: width,
            currentCount: width
        ))

        let olderChildren = (0..<width).map {
            node("Table scan", relation: "table_\($0)")
        }
        var currentChildren = olderChildren
        let middle = width / 2
        currentChildren.swapAt(middle, middle + 1)
        let older = plan(root: node("Nested loop", children: olderChildren))
        let current = plan(root: node("Nested loop", children: currentChildren))
        let first = QueryPlanComparison(previous: older, current: current)
        let second = QueryPlanComparison(previous: older, current: current)

        #expect(first.hasChanges)
        #expect(first.nodeChanges.count == 4)
        #expect(first.nodeChanges == second.nodeChanges)
        #expect(first.nodeChanges.filter { $0.kind == .removed }.count == 2)
        #expect(first.nodeChanges.filter { $0.kind == .added }.count == 2)
    }

    @Test("Visible property changes modify a node while hidden noise is ignored")
    func comparesVisiblePropertiesOnly() throws {
        let older = plan(root: node("Seq Scan", relation: "users", properties: [
            "Filter": "active = true",
            "Parallel Aware": "false",
        ]))
        let current = plan(root: node("Seq Scan", relation: "users", properties: [
            "Filter": "active = false",
            "Parallel Aware": "true",
        ]))
        let comparison = QueryPlanComparison(previous: older, current: current)
        let change = try #require(comparison.nodeChanges.first)

        #expect(comparison.nodeChanges.count == 1)
        #expect(change.kind == .modified)
        #expect(change.valueChanges.count == 1)
        #expect(change.valueChanges.first?.category == .property)
        #expect(change.valueChanges.first?.name == "Filter")
    }

    @Test("Missing metrics keep deltas and percentages nil")
    func handlesNilMetrics() {
        let comparison = QueryPlanComparison(
            previous: plan(root: node("Result")),
            current: plan(root: node("Result", totalCost: 2))
        )

        #expect(comparison.summary.rootEstimatedTotalCost.previous == nil)
        #expect(comparison.summary.rootEstimatedTotalCost.current == 2)
        #expect(comparison.summary.rootEstimatedTotalCost.delta == nil)
        #expect(comparison.summary.rootEstimatedTotalCost.percentChange == nil)
    }

    @Test("A zero baseline does not divide when computing percentage")
    func handlesZeroBaseline() {
        let delta = QueryPlanMetricDelta(previous: 0, current: 5)

        #expect(delta.delta == 5)
        #expect(delta.percentChange == nil)
    }

    @Test("All summary deltas point from older to current")
    func preservesComparisonDirection() {
        let older = plan(
            root: node("Append", totalCost: 20, rows: 100, children: [node("Result")]),
            planningTime: 4,
            executionTime: 10
        )
        let current = plan(
            root: node("Append", totalCost: 15, rows: 140, children: [node("Result"), node("Hash")]),
            planningTime: 3,
            executionTime: 12
        )
        let summary = QueryPlanComparison(previous: older, current: current).summary

        #expect(summary.rootEstimatedTotalCost.delta == -5)
        #expect(summary.rootEstimatedTotalCost.percentChange == -25)
        #expect(summary.rootEstimatedRows.delta == 40)
        #expect(summary.planningTime.delta == -1)
        #expect(summary.executionTime.delta == 2)
        #expect(summary.nodeCount.delta == 1)
    }
}
