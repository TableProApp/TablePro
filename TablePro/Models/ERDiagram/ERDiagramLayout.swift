import AppKit
import Foundation
import os

/// Sugiyama-style layered layout for ER diagrams.
/// Produces node center positions from a graph of tables and FK edges.
enum ERDiagramLayout {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ERDiagramLayout")

    /// Multiplier derived from the user's system text-size preference.
    /// 1.0 at the default (~13pt body), grows with Larger Accessibility Sizes.
    static var typeScale: CGFloat {
        max(1.0, NSFont.preferredFont(forTextStyle: .body).pointSize / 13.0)
    }

    static var nodeWidth: CGFloat { 220 * typeScale }
    static let horizontalGap: CGFloat = 60
    static let verticalGap: CGFloat = 40
    static var headerHeight: CGFloat { 36 * typeScale }
    static var columnRowHeight: CGFloat { 22 * typeScale }

    static func compute(
        graph: ERDiagramGraph
    ) -> [UUID: CGPoint] {
        guard !graph.nodes.isEmpty else { return [:] }

        let adjacency = buildAdjacency(graph: graph)
        let dagEdges = breakCycles(adjacency: adjacency, nodeIds: graph.nodes.map(\.id))
        let layers = assignLayers(dagEdges: dagEdges, nodeIds: graph.nodes.map(\.id), graph: graph)
        let orderedLayers = minimizeCrossings(layers: layers, dagEdges: dagEdges)
        return assignCoordinates(orderedLayers: orderedLayers, graph: graph)
    }

    static func estimateHeight(columnCount: Int) -> CGFloat {
        headerHeight + CGFloat(max(columnCount, 1)) * columnRowHeight
    }

    // MARK: - Adjacency

    private static func buildAdjacency(graph: ERDiagramGraph) -> [UUID: [UUID]] {
        var adj: [UUID: [UUID]] = [:]
        for node in graph.nodes {
            adj[node.id] = []
        }
        for edge in graph.edges {
            guard let fromId = graph.nodeIndex[edge.fromTable],
                  let toId = graph.nodeIndex[edge.toTable]
            else { continue }
            // FK owner → referenced table (child → parent in ER terms)
            adj[fromId, default: []].append(toId)
        }
        return adj
    }

    // MARK: - Cycle Breaking (DFS)

    private static func breakCycles(adjacency: [UUID: [UUID]], nodeIds: [UUID]) -> [UUID: [UUID]] {
        var visited: Set<UUID> = []
        var onStack: Set<UUID> = []
        var dag = adjacency
        var backEdges: [(UUID, UUID)] = []

        for startNode in nodeIds where !visited.contains(startNode) {
            // Iterative DFS using explicit stack
            // Each entry: (node, neighborIndex)
            var stack: [(node: UUID, idx: Int)] = [(startNode, 0)]
            visited.insert(startNode)
            onStack.insert(startNode)

            while !stack.isEmpty {
                let (node, idx) = stack[stack.count - 1]
                let neighbors = adjacency[node] ?? []

                if idx < neighbors.count {
                    stack[stack.count - 1].idx += 1
                    let neighbor = neighbors[idx]
                    if onStack.contains(neighbor) {
                        backEdges.append((node, neighbor))
                    } else if !visited.contains(neighbor) {
                        visited.insert(neighbor)
                        onStack.insert(neighbor)
                        stack.append((neighbor, 0))
                    }
                } else {
                    onStack.remove(node)
                    stack.removeLast()
                }
            }
        }

        for (from, to) in backEdges {
            dag[from]?.removeAll { $0 == to }
        }

        return dag
    }

    // MARK: - Layer Assignment (Longest Path)

    private static func assignLayers(
        dagEdges: [UUID: [UUID]],
        nodeIds: [UUID],
        graph: ERDiagramGraph
    ) -> [[UUID]] {
        // Build reverse adjacency (incoming edges)
        var inDegree: [UUID: Int] = [:]
        for id in nodeIds { inDegree[id] = 0 }
        for (_, neighbors) in dagEdges {
            for n in neighbors { inDegree[n, default: 0] += 1 }
        }

        // Topological sort via Kahn's algorithm
        var queue = nodeIds.filter { (inDegree[$0] ?? 0) == 0 }
        var layerAssignment: [UUID: Int] = [:]
        for id in queue { layerAssignment[id] = 0 }

        var idx = 0
        while idx < queue.count {
            let node = queue[idx]
            idx += 1
            let currentLayer = layerAssignment[node] ?? 0
            for neighbor in dagEdges[node] ?? [] {
                let newLayer = currentLayer + 1
                if newLayer > (layerAssignment[neighbor] ?? 0) {
                    layerAssignment[neighbor] = newLayer
                }
                inDegree[neighbor] = (inDegree[neighbor] ?? 1) - 1
                if inDegree[neighbor] == 0 {
                    queue.append(neighbor)
                }
            }
        }

        // Assign any unvisited nodes (disconnected) to layer 0
        let unassigned = nodeIds.filter { layerAssignment[$0] == nil }
        if !unassigned.isEmpty {
            logger.debug("Sugiyama: \(unassigned.count) nodes fell through to layer 0 (disconnected or cycle remnants)")
        }
        for id in unassigned {
            layerAssignment[id] = 0
        }

        // Group by layer
        var layers: [Int: [UUID]] = [:]
        for (id, layer) in layerAssignment {
            layers[layer, default: []].append(id)
        }

        let maxLayer = layers.keys.max() ?? 0
        return (0...maxLayer).map { layers[$0] ?? [] }
    }

    // MARK: - Crossing Minimization (Barycentric)

    private static func minimizeCrossings(layers: [[UUID]], dagEdges: [UUID: [UUID]]) -> [[UUID]] {
        guard layers.count > 1 else { return layers }

        var reverseEdges: [UUID: [UUID]] = [:]
        for (from, neighbors) in dagEdges {
            for to in neighbors {
                reverseEdges[to, default: []].append(from)
            }
        }

        var result = layers
        let sweepCount = min(layers.count * 2, 8)

        for sweep in 0..<sweepCount {
            if sweep.isMultiple(of: 2) {
                // Top-down sweep
                for layerIdx in 1..<result.count {
                    let upperPositions: [UUID: Int] = Dictionary(
                        uniqueKeysWithValues: result[layerIdx - 1].enumerated().map { ($1, $0) }
                    )
                    var barycenters: [UUID: Double] = [:]
                    for node in result[layerIdx] {
                        let positions = (reverseEdges[node] ?? []).compactMap { upperPositions[$0] }
                        if !positions.isEmpty {
                            barycenters[node] = Double(positions.reduce(0, +)) / Double(positions.count)
                        }
                    }
                    result[layerIdx].sort { (barycenters[$0] ?? .infinity) < (barycenters[$1] ?? .infinity) }
                }
            } else {
                // Bottom-up sweep
                for layerIdx in stride(from: result.count - 2, through: 0, by: -1) {
                    let lowerPositions: [UUID: Int] = Dictionary(
                        uniqueKeysWithValues: result[layerIdx + 1].enumerated().map { ($1, $0) }
                    )
                    var barycenters: [UUID: Double] = [:]
                    for node in result[layerIdx] {
                        let positions = (dagEdges[node] ?? []).compactMap { lowerPositions[$0] }
                        if !positions.isEmpty {
                            barycenters[node] = Double(positions.reduce(0, +)) / Double(positions.count)
                        }
                    }
                    result[layerIdx].sort { (barycenters[$0] ?? .infinity) < (barycenters[$1] ?? .infinity) }
                }
            }
        }

        return result
    }

    // MARK: - Coordinate Assignment (top-to-bottom, center-aligned)

    private static func assignCoordinates(
        orderedLayers: [[UUID]],
        graph: ERDiagramGraph
    ) -> [UUID: CGPoint] {
        var positions: [UUID: CGPoint] = [:]
        let nodeById: [UUID: ERTableNode] = Dictionary(
            uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) }
        )
        let nodeColumnCounts: [UUID: Int] = nodeById.mapValues(\.displayColumns.count)

        // Separate connected and isolated layers
        let allConnected = Set(graph.edges.flatMap { [$0.fromTable, $0.toTable] })
        var connectedLayers: [[UUID]] = []
        var isolatedNodes: [UUID] = []

        for layer in orderedLayers {
            var connected: [UUID] = []
            for nodeId in layer {
                let tableName = nodeById[nodeId]?.tableName ?? ""
                if allConnected.contains(tableName) {
                    connected.append(nodeId)
                } else {
                    isolatedNodes.append(nodeId)
                }
            }
            if !connected.isEmpty {
                connectedLayers.append(connected)
            }
        }

        // Top-to-bottom: y = layer row, x = position within layer (center-aligned)
        let padding: CGFloat = 40
        var currentY: CGFloat = padding
        let totalConnectedNodes = connectedLayers.reduce(0) { $0 + $1.count }

        for layer in connectedLayers {
            let layerWidth = CGFloat(layer.count) * nodeWidth + CGFloat(max(layer.count - 1, 0)) * horizontalGap
            var currentX = padding + (nodeWidth / 2)
            var maxHeight: CGFloat = 0

            // Center the layer horizontally
            let totalWidth = max(layerWidth, CGFloat(totalConnectedNodes) * (nodeWidth + horizontalGap))
            let layerOffset = (totalWidth - layerWidth) / 2
            currentX += layerOffset

            for nodeId in layer {
                let colCount = nodeColumnCounts[nodeId] ?? 1
                let height = estimateHeight(columnCount: colCount)

                positions[nodeId] = CGPoint(x: currentX, y: currentY + height / 2)
                currentX += nodeWidth + horizontalGap
                maxHeight = max(maxHeight, height)
            }

            currentY += maxHeight + verticalGap
        }

        // Place isolated tables in a grid below the connected layers
        if !isolatedNodes.isEmpty {
            currentY += verticalGap
            let gridColumns = max(Int(sqrt(Double(isolatedNodes.count))), 3)
            var col = 0
            var rowMaxHeight: CGFloat = 0

            for nodeId in isolatedNodes {
                let colCount = nodeColumnCounts[nodeId] ?? 1
                let height = estimateHeight(columnCount: colCount)
                let x = padding + nodeWidth / 2 + CGFloat(col) * (nodeWidth + horizontalGap)

                positions[nodeId] = CGPoint(x: x, y: currentY + height / 2)
                rowMaxHeight = max(rowMaxHeight, height)

                col += 1
                if col >= gridColumns {
                    col = 0
                    currentY += rowMaxHeight + verticalGap
                    rowMaxHeight = 0
                }
            }
        }

        return positions
    }
}
