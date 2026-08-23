//
//  QueryPlanOutlineSortTests.swift
//  TableProTests
//
//  Sorting the plan outline reorders siblings only. Flattening a plan would destroy it, since a
//  join's inputs are not interchangeable with a subtree at another depth.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Query Plan Outline Sort")
@MainActor
struct QueryPlanOutlineSortTests {
    private func node(
        _ operation: String,
        cost: Double? = nil,
        rows: Int? = nil,
        actualTime: Double? = nil,
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
            actualRows: nil, actualLoops: nil,
            properties: [:],
            children: children
        )
    }

    private func makeTree() -> QueryPlanNode {
        node("Nested Loop", cost: 100, rows: 500, actualTime: 9, children: [
            node("Seq Scan", cost: 10, rows: 300, actualTime: 5, children: [
                node("Inner B", cost: 2, rows: 20, actualTime: 1),
                node("Inner A", cost: 8, rows: 10, actualTime: 4),
            ]),
            node("Index Scan", cost: 80, rows: 100, actualTime: 2),
        ])
    }

    @Test("Sorting by cost reorders siblings without flattening the tree")
    func sortsSiblingsByCost() {
        let root = QueryPlanOutlineNode(makeTree())
        let sorted = root.sorted(by: QueryPlanOutlineSort.comparator(key: .cost, ascending: false))

        #expect(sorted.source.operation == "Nested Loop")
        #expect(sorted.children.count == 2)
        #expect(sorted.children[0].source.operation == "Index Scan")
        #expect(sorted.children[1].source.operation == "Seq Scan")
        #expect(sorted.children[1].children.count == 2)
        #expect(sorted.children[1].children[0].source.operation == "Inner A")
    }

    @Test("Ascending and descending are mirror images")
    func mirrorsDirection() {
        let root = QueryPlanOutlineNode(makeTree())
        let ascending = root.sorted(by: QueryPlanOutlineSort.comparator(key: .cost, ascending: true))
        let descending = root.sorted(by: QueryPlanOutlineSort.comparator(key: .cost, ascending: false))

        #expect(ascending.children.map { $0.source.operation }.reversed()
            == descending.children.map { $0.source.operation })
    }

    @Test("The root is never reordered away")
    func keepsRootInPlace() {
        let root = QueryPlanOutlineNode(makeTree())
        for column in QueryPlanOutlineColumn.allCases {
            let sorted = root.sorted(by: QueryPlanOutlineSort.comparator(key: column, ascending: true))
            #expect(sorted.source.operation == "Nested Loop")
        }
    }

    @Test("Sorting preserves every node")
    func preservesNodeCount() {
        func count(_ node: QueryPlanOutlineNode) -> Int {
            1 + node.children.reduce(0) { $0 + count($1) }
        }

        let root = QueryPlanOutlineNode(makeTree())
        let sorted = root.sorted(by: QueryPlanOutlineSort.comparator(key: .rows, ascending: true))
        #expect(count(sorted) == count(root))
    }

    @Test("Nodes with no value sort below nodes that have one")
    func sinksMissingValues() {
        let tree = node("Root", cost: 10, children: [
            node("No Time", cost: 1),
            node("Has Time", cost: 1, actualTime: 4),
        ])
        let sorted = QueryPlanOutlineNode(tree)
            .sorted(by: QueryPlanOutlineSort.comparator(key: .actualTime, ascending: false))

        #expect(sorted.children[0].source.operation == "Has Time")
    }

    @Test("Names sort A to Z by default, numbers worst first")
    func picksSensibleDefaultDirection() {
        #expect(QueryPlanOutlineSort.defaultAscending(for: .operation))
        #expect(!QueryPlanOutlineSort.defaultAscending(for: .cost))
        #expect(!QueryPlanOutlineSort.defaultAscending(for: .rows))
        #expect(!QueryPlanOutlineSort.defaultAscending(for: .actualTime))
    }

    @Test("Every column has a localized title and a usable width")
    func describesColumns() {
        for column in QueryPlanOutlineColumn.allCases {
            #expect(!column.title.isEmpty)
            #expect(column.minimumWidth > 0)
            #expect(column.width >= column.minimumWidth)
        }
    }
}
