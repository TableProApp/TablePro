//
//  ERDiagramLayoutTests.swift
//  TableProTests
//
//  Tests the component-aware compact layout used by the ER diagram.
//

import CoreGraphics
import Foundation
@testable import TablePro
import Testing

@Suite("ER diagram layout")
struct ERDiagramLayoutTests {
    private func column(_ name: String) -> ERColumnDisplay {
        ERColumnDisplay(id: name, name: name, dataType: "int", isPrimaryKey: false, isForeignKey: false, isNullable: true)
    }

    private func makeGraph(
        tables: [String],
        columnsPerTable: Int = 3,
        foreignKeys: [(from: String, to: String)] = []
    ) -> ERDiagramGraph {
        let nodes = tables.map { name -> ERTableNode in
            let cols = (0..<columnsPerTable).map { column("\(name)_\($0)") }
            return ERTableNode(id: UUID(), tableName: name, columns: cols, displayColumns: cols, clusterId: nil)
        }
        let index = Dictionary(uniqueKeysWithValues: nodes.map { ($0.tableName, $0.id) })
        let edges = foreignKeys.enumerated().map { offset, fk in
            EREdge(
                id: UUID(),
                fkName: "fk_\(offset)",
                fromTable: fk.from,
                fromColumn: "ref_id",
                toTable: fk.to,
                toColumn: "id",
                cardinality: .manyToOne
            )
        }
        let clusters = ERClusterAnalyzer.assignClusters(nodes: nodes, edges: edges, nodeIndex: index)
        let clustered = nodes.map { node -> ERTableNode in
            var updated = node
            updated.clusterId = clusters[node.id]
            return updated
        }
        return ERDiagramGraph(nodes: clustered, edges: edges, nodeIndex: index)
    }

    private func rect(for node: ERTableNode, at center: CGPoint) -> CGRect {
        let height = ERDiagramLayout.estimateHeight(columnCount: node.displayColumns.count)
        return CGRect(
            x: center.x - ERDiagramLayout.nodeWidth / 2,
            y: center.y - height / 2,
            width: ERDiagramLayout.nodeWidth,
            height: height
        )
    }

    @Test("An empty graph produces no positions")
    func empty() {
        let layout = ERDiagramLayout.compute(graph: .empty)
        #expect(layout.isEmpty)
    }

    @Test("Every node receives a position")
    func everyNodePositioned() {
        let graph = makeGraph(
            tables: ["a", "b", "c", "d", "e"],
            foreignKeys: [("a", "b"), ("b", "c"), ("d", "e")]
        )
        let layout = ERDiagramLayout.compute(graph: graph)
        #expect(Set(layout.keys) == Set(graph.nodes.map(\.id)))
    }

    @Test("Layout is deterministic across runs")
    func deterministic() {
        let graph = makeGraph(
            tables: ["orders", "items", "users", "tags", "logs"],
            foreignKeys: [("items", "orders"), ("orders", "users"), ("tags", "users")]
        )
        let first = ERDiagramLayout.compute(graph: graph)
        let second = ERDiagramLayout.compute(graph: graph)
        #expect(first == second)
    }

    @Test("No two table boxes overlap")
    func noOverlap() {
        let graph = makeGraph(
            tables: ["a", "b", "c", "m", "n", "p", "q"],
            foreignKeys: [("a", "b"), ("b", "c"), ("m", "n")]
        )
        let layout = ERDiagramLayout.compute(graph: graph)
        let rects = graph.nodes.compactMap { node in layout[node.id].map { rect(for: node, at: $0) } }

        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count {
                #expect(!rects[i].intersects(rects[j]))
            }
        }
    }

    @Test("Separate components occupy disjoint regions")
    func componentsDisjoint() {
        let graph = makeGraph(
            tables: ["a", "b", "c", "d"],
            foreignKeys: [("a", "b"), ("c", "d")]
        )
        let layout = ERDiagramLayout.compute(graph: graph)

        func bounds(_ names: [String]) -> CGRect {
            graph.nodes
                .filter { names.contains($0.tableName) }
                .compactMap { node in layout[node.id].map { rect(for: node, at: $0) } }
                .reduce(CGRect.null) { $0.union($1) }
        }

        #expect(!bounds(["a", "b"]).intersects(bounds(["c", "d"])))
    }

    @Test("Isolated tables fill horizontal space instead of stacking vertically")
    func isolatedTablesUseWidth() {
        let graph = makeGraph(tables: (0..<9).map { "t\($0)" })
        let layout = ERDiagramLayout.compute(graph: graph)
        let bounds = graph.nodes
            .compactMap { node in layout[node.id].map { rect(for: node, at: $0) } }
            .reduce(CGRect.null) { $0.union($1) }

        #expect(bounds.width > ERDiagramLayout.nodeWidth * 2)
    }

    @Test("A single table is positioned")
    func singleTable() {
        let graph = makeGraph(tables: ["solo"])
        let layout = ERDiagramLayout.compute(graph: graph)
        #expect(layout.count == 1)
    }

    @Test("A long foreign-key chain does not stack into a tall narrow column")
    func longChainStaysCompact() {
        let tables = (0..<10).map { "t\($0)" }
        let chainFks = (0..<9).map { (from: "t\($0)", to: "t\($0 + 1)") }
        let graph = makeGraph(tables: tables, foreignKeys: chainFks)
        let layout = ERDiagramLayout.compute(graph: graph)
        let bounds = graph.nodes
            .compactMap { node in layout[node.id].map { rect(for: node, at: $0) } }
            .reduce(CGRect.null) { $0.union($1) }

        let aspect = bounds.width / bounds.height
        #expect(aspect > 0.7)
        #expect(aspect < 4.0)
    }
}
