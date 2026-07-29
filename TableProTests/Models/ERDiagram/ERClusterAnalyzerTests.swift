//
//  ERClusterAnalyzerTests.swift
//  TableProTests
//
//  Tests connected-component cluster assignment for the ER diagram.
//

import Foundation
@testable import TablePro
import Testing

@Suite("ER cluster analyzer")
struct ERClusterAnalyzerTests {
    private func node(_ name: String) -> ERTableNode {
        ERTableNode(id: UUID(), tableName: name, columns: [], displayColumns: [], clusterId: nil)
    }

    private func makeGraph(
        tables: [String],
        foreignKeys: [(from: String, to: String)]
    ) -> (nodes: [ERTableNode], edges: [EREdge], index: [String: UUID]) {
        let nodes = tables.map(node)
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
        return (nodes, edges, index)
    }

    private func clusterId(of name: String, clusters: [UUID: Int], nodes: [ERTableNode]) -> Int? {
        nodes.first { $0.tableName == name }.flatMap { clusters[$0.id] }
    }

    @Test("Two separate components get distinct cluster ids ordered by name")
    func twoComponents() {
        let graph = makeGraph(tables: ["a", "b", "c", "d"], foreignKeys: [("a", "b"), ("c", "d")])
        let clusters = ERClusterAnalyzer.assignClusters(nodes: graph.nodes, edges: graph.edges, nodeIndex: graph.index)

        #expect(clusterId(of: "a", clusters: clusters, nodes: graph.nodes) == 0)
        #expect(clusterId(of: "b", clusters: clusters, nodes: graph.nodes) == 0)
        #expect(clusterId(of: "c", clusters: clusters, nodes: graph.nodes) == 1)
        #expect(clusterId(of: "d", clusters: clusters, nodes: graph.nodes) == 1)
    }

    @Test("A chain forms a single cluster")
    func chain() {
        let graph = makeGraph(tables: ["a", "b", "c"], foreignKeys: [("a", "b"), ("b", "c")])
        let clusters = ERClusterAnalyzer.assignClusters(nodes: graph.nodes, edges: graph.edges, nodeIndex: graph.index)

        #expect(["a", "b", "c"].allSatisfy { clusterId(of: $0, clusters: clusters, nodes: graph.nodes) == 0 })
    }

    @Test("A star forms a single cluster")
    func star() {
        let graph = makeGraph(
            tables: ["hub", "x", "y", "z"],
            foreignKeys: [("x", "hub"), ("y", "hub"), ("z", "hub")]
        )
        let clusters = ERClusterAnalyzer.assignClusters(nodes: graph.nodes, edges: graph.edges, nodeIndex: graph.index)

        #expect(["hub", "x", "y", "z"].allSatisfy { clusterId(of: $0, clusters: clusters, nodes: graph.nodes) == 0 })
    }

    @Test("Tables with no foreign keys stay uncolored")
    func isolatedTables() {
        let graph = makeGraph(tables: ["a", "b", "c"], foreignKeys: [])
        let clusters = ERClusterAnalyzer.assignClusters(nodes: graph.nodes, edges: graph.edges, nodeIndex: graph.index)

        #expect(clusters.isEmpty)
    }

    @Test("A self-referencing table stays a singleton")
    func selfReference() {
        let graph = makeGraph(tables: ["employee"], foreignKeys: [("employee", "employee")])
        let clusters = ERClusterAnalyzer.assignClusters(nodes: graph.nodes, edges: graph.edges, nodeIndex: graph.index)

        #expect(clusterId(of: "employee", clusters: clusters, nodes: graph.nodes) == nil)
    }

    @Test("A connected pair and an isolated table coexist")
    func mixed() {
        let graph = makeGraph(tables: ["a", "b", "loner"], foreignKeys: [("a", "b")])
        let clusters = ERClusterAnalyzer.assignClusters(nodes: graph.nodes, edges: graph.edges, nodeIndex: graph.index)

        #expect(clusterId(of: "a", clusters: clusters, nodes: graph.nodes) == 0)
        #expect(clusterId(of: "b", clusters: clusters, nodes: graph.nodes) == 0)
        #expect(clusterId(of: "loner", clusters: clusters, nodes: graph.nodes) == nil)
    }

    @Test("Assignment is deterministic across runs")
    func deterministic() {
        let graph = makeGraph(
            tables: ["a", "b", "c", "d", "e"],
            foreignKeys: [("a", "b"), ("c", "d"), ("d", "e")]
        )
        let first = ERClusterAnalyzer.assignClusters(nodes: graph.nodes, edges: graph.edges, nodeIndex: graph.index)
        let second = ERClusterAnalyzer.assignClusters(nodes: graph.nodes, edges: graph.edges, nodeIndex: graph.index)

        #expect(first == second)
    }

    @Test("An empty graph yields no clusters")
    func empty() {
        let clusters = ERClusterAnalyzer.assignClusters(nodes: [], edges: [], nodeIndex: [:])
        #expect(clusters.isEmpty)
    }
}
