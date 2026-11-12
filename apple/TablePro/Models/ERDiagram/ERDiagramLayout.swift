import AppKit
import Foundation
import os

/// Component-aware compact layout for ER diagrams.
/// Detects connected components, places each with a force-directed pass, then packs
/// the component blocks into the 2D plane so the diagram fills both axes.
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
    static let blockGap: CGFloat = 80
    static var headerHeight: CGFloat { 36 * typeScale }
    static var columnRowHeight: CGFloat { 22 * typeScale }

    private struct Block {
        let positions: [UUID: CGPoint]
        let size: CGSize
    }

    // Off the caller's actor, so a superseded layout's task cancels the work itself and not only its result.
    @concurrent
    static func layOut(_ graph: ERDiagramGraph) async throws -> [UUID: CGPoint] {
        try compute(graph: graph)
    }

    static func compute(graph: ERDiagramGraph) throws -> [UUID: CGPoint] {
        guard !graph.nodes.isEmpty else { return [:] }

        let sizes = nodeSizes(graph: graph)
        let adjacency = undirectedAdjacency(graph: graph)

        var componentGroups: [Int: [UUID]] = [:]
        var singletons: [UUID] = []
        for node in graph.nodes.sorted(by: { $0.tableName < $1.tableName }) {
            if let clusterId = node.clusterId {
                componentGroups[clusterId, default: []].append(node.id)
            } else {
                singletons.append(node.id)
            }
        }

        var blocks: [Block] = []
        for clusterId in componentGroups.keys.sorted() {
            let members = componentGroups[clusterId] ?? []
            let local = try forceDirected(members: members, adjacency: adjacency, sizes: sizes)
            blocks.append(makeBlock(centers: local, members: members, sizes: sizes))
        }
        if !singletons.isEmpty {
            blocks.append(gridBlock(members: singletons, sizes: sizes))
        }

        let placements = packBlocks(blocks.map(\.size))
        return composeCenters(blocks: blocks, placements: placements, sizes: sizes)
    }

    static func estimateHeight(columnCount: Int) -> CGFloat {
        headerHeight + CGFloat(max(columnCount, 1)) * columnRowHeight
    }

    // MARK: - Graph Derivations

    private static func nodeSizes(graph: ERDiagramGraph) -> [UUID: CGSize] {
        Dictionary(uniqueKeysWithValues: graph.nodes.map { node in
            (node.id, CGSize(width: nodeWidth, height: estimateHeight(columnCount: node.displayColumns.count)))
        })
    }

    private static func undirectedAdjacency(graph: ERDiagramGraph) -> [UUID: [UUID]] {
        var adjacency: [UUID: [UUID]] = [:]
        for edge in graph.edges {
            guard let from = graph.nodeIndex[edge.fromTable],
                  let to = graph.nodeIndex[edge.toTable],
                  from != to
            else { continue }
            adjacency[from, default: []].append(to)
            adjacency[to, default: []].append(from)
        }
        return adjacency
    }

    // MARK: - Force-Directed Component Layout

    // A component is indexed by its members' order, so each step reads and writes arrays rather than
    // hashing a UUID per pair: a 300-table component took 1.1 s that way and takes 11 ms this way, measured.
    private static func forceDirected(
        members: [UUID],
        adjacency: [UUID: [UUID]],
        sizes: [UUID: CGSize]
    ) throws -> [UUID: CGPoint] {
        guard let first = members.first else { return [:] }
        guard members.count > 1 else { return [first: .zero] }

        let count = members.count
        let spacing = idealDistance(members: members, sizes: sizes)
        let edges = uniqueEdges(members: members, adjacency: adjacency)
        var degree = ContiguousArray(repeating: 0, count: count)
        for (source, target) in edges {
            degree[source] += 1
            degree[target] += 1
        }
        var positions = circularInit(count: count, idealDistance: spacing)
        let iterations = max(60, min(300, 2_000 / count))
        var temperature = spacing * 2

        for _ in 0..<iterations {
            try Task.checkCancellation()
            let displacement = forceStep(edges: edges, degree: degree, positions: positions, idealDistance: spacing)
            for index in 0..<count {
                let move = displacement[index]
                let length = max(hypot(move.dx, move.dy), 0.0001)
                let limited = min(length, temperature)
                positions[index] = CGPoint(
                    x: positions[index].x + move.dx / length * limited,
                    y: positions[index].y + move.dy / length * limited
                )
            }
            temperature = max(temperature * 0.95, spacing * 0.05)
        }

        rotateToLandscape(&positions)
        let boxes = ContiguousArray(members.map { sizes[$0] })
        try removeOverlaps(positions: &positions, sizes: boxes)

        var placed: [UUID: CGPoint] = [:]
        placed.reserveCapacity(count)
        for (index, id) in members.enumerated() {
            placed[id] = positions[index]
        }
        return placed
    }

    private static func rotateToLandscape(_ positions: inout ContiguousArray<CGPoint>) {
        guard positions.count > 2 else { return }
        var centerX: CGFloat = 0
        var centerY: CGFloat = 0
        for position in positions {
            centerX += position.x
            centerY += position.y
        }
        centerX /= CGFloat(positions.count)
        centerY /= CGFloat(positions.count)

        var sxx: CGFloat = 0
        var syy: CGFloat = 0
        var sxy: CGFloat = 0
        for position in positions {
            let dx = position.x - centerX
            let dy = position.y - centerY
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }

        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        let cosT = cos(-theta)
        let sinT = sin(-theta)
        for index in positions.indices {
            let dx = positions[index].x - centerX
            let dy = positions[index].y - centerY
            positions[index] = CGPoint(x: centerX + dx * cosT - dy * sinT, y: centerY + dx * sinT + dy * cosT)
        }
    }

    // Each pair once, in the order the members first reach it.
    private static func uniqueEdges(members: [UUID], adjacency: [UUID: [UUID]]) -> [(Int, Int)] {
        var indexOf: [UUID: Int] = [:]
        indexOf.reserveCapacity(members.count)
        for (index, id) in members.enumerated() {
            indexOf[id] = index
        }
        var seen: Set<Int> = []
        var edges: [(Int, Int)] = []
        for (source, id) in members.enumerated() {
            for neighbor in adjacency[id] ?? [] {
                guard let target = indexOf[neighbor] else { continue }
                let key = min(source, target) * members.count + max(source, target)
                guard seen.insert(key).inserted else { continue }
                edges.append((source, target))
            }
        }
        return edges
    }

    private static func forceStep(
        edges: [(Int, Int)],
        degree: ContiguousArray<Int>,
        positions: ContiguousArray<CGPoint>,
        idealDistance: CGFloat
    ) -> ContiguousArray<CGVector> {
        let count = positions.count
        var displacement = ContiguousArray(repeating: CGVector.zero, count: count)

        var centerX: CGFloat = 0
        var centerY: CGFloat = 0
        for position in positions {
            centerX += position.x
            centerY += position.y
        }
        centerX /= CGFloat(count)
        centerY /= CGFloat(count)

        for i in 0..<count {
            let posLhs = positions[i]
            for j in (i + 1)..<count {
                let posRhs = positions[j]
                var dx = posLhs.x - posRhs.x
                var dy = posLhs.y - posRhs.y
                var distance = hypot(dx, dy)
                if distance < 0.01 {
                    dx = CGFloat(i - j)
                    dy = 1
                    distance = hypot(dx, dy)
                }
                let repulsion = idealDistance * idealDistance / distance
                let unitX = dx / distance
                let unitY = dy / distance
                displacement[i].dx += unitX * repulsion
                displacement[i].dy += unitY * repulsion
                displacement[j].dx -= unitX * repulsion
                displacement[j].dy -= unitY * repulsion
            }
        }

        for (source, target) in edges {
            let posSource = positions[source]
            let posTarget = positions[target]
            let dx = posSource.x - posTarget.x
            let dy = posSource.y - posTarget.y
            let distance = max(hypot(dx, dy), 0.01)
            let attraction = distance * distance / idealDistance
            let unitX = dx / distance
            let unitY = dy / distance
            displacement[source].dx -= unitX * attraction
            displacement[source].dy -= unitY * attraction
            displacement[target].dx += unitX * attraction
            displacement[target].dy += unitY * attraction
        }

        let gravity: CGFloat = 0.28
        for index in 0..<count {
            let position = positions[index]
            let dx = centerX - position.x
            let dy = centerY - position.y
            let distance = max(hypot(dx, dy), 0.01)
            let pull = gravity * CGFloat(degree[index] + 1) * distance
            displacement[index].dx += dx / distance * pull
            displacement[index].dy += dy / distance * pull
        }

        return displacement
    }

    private static func idealDistance(members: [UUID], sizes: [UUID: CGSize]) -> CGFloat {
        let count = CGFloat(max(members.count, 1))
        let avgWidth = members.reduce(0) { $0 + (sizes[$1]?.width ?? nodeWidth) } / count
        let avgHeight = members.reduce(0) { $0 + (sizes[$1]?.height ?? headerHeight) } / count
        return (avgWidth + avgHeight) * 0.8 + horizontalGap
    }

    private static func circularInit(count: Int, idealDistance: CGFloat) -> ContiguousArray<CGPoint> {
        let radius = idealDistance * CGFloat(count) / (2 * .pi) + idealDistance
        var positions = ContiguousArray<CGPoint>()
        positions.reserveCapacity(count)
        for index in 0..<count {
            let angle = 2 * CGFloat.pi * CGFloat(index) / CGFloat(count)
            positions.append(CGPoint(x: radius * cos(angle), y: radius * sin(angle)))
        }
        return positions
    }

    private static func removeOverlaps(
        positions: inout ContiguousArray<CGPoint>,
        sizes: ContiguousArray<CGSize?>
    ) throws {
        let count = positions.count
        let padding = horizontalGap * 0.5
        let passes = max(20, min(count, 60))
        for _ in 0..<passes {
            try Task.checkCancellation()
            var moved = false
            for i in 0..<count {
                guard let sizeLhs = sizes[i] else { continue }
                for j in (i + 1)..<count {
                    guard let sizeRhs = sizes[j] else { continue }
                    let posLhs = positions[i]
                    let posRhs = positions[j]
                    let overlapX = (sizeLhs.width + sizeRhs.width) / 2 + padding - abs(posLhs.x - posRhs.x)
                    let overlapY = (sizeLhs.height + sizeRhs.height) / 2 + padding - abs(posLhs.y - posRhs.y)
                    guard overlapX > 0, overlapY > 0 else { continue }
                    moved = true
                    if overlapX < overlapY {
                        let shift = overlapX / 2 * (posLhs.x >= posRhs.x ? 1 : -1)
                        positions[i].x += shift
                        positions[j].x -= shift
                    } else {
                        let shift = overlapY / 2 * (posLhs.y >= posRhs.y ? 1 : -1)
                        positions[i].y += shift
                        positions[j].y -= shift
                    }
                }
            }
            if !moved { break }
        }
    }

    // MARK: - Blocks

    private static func makeBlock(
        centers: [UUID: CGPoint],
        members: [UUID],
        sizes: [UUID: CGSize]
    ) -> Block {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for id in members {
            let center = centers[id] ?? .zero
            let size = sizes[id] ?? CGSize(width: nodeWidth, height: estimateHeight(columnCount: 1))
            minX = min(minX, center.x - size.width / 2)
            minY = min(minY, center.y - size.height / 2)
            maxX = max(maxX, center.x + size.width / 2)
            maxY = max(maxY, center.y + size.height / 2)
        }

        var positions: [UUID: CGPoint] = [:]
        for id in members {
            let center = centers[id] ?? .zero
            let size = sizes[id] ?? CGSize(width: nodeWidth, height: estimateHeight(columnCount: 1))
            positions[id] = CGPoint(x: center.x - size.width / 2 - minX, y: center.y - size.height / 2 - minY)
        }
        return Block(positions: positions, size: CGSize(width: maxX - minX, height: maxY - minY))
    }

    private static func gridBlock(members: [UUID], sizes: [UUID: CGSize]) -> Block {
        let columns = max(1, Int(ceil(sqrt(Double(members.count)))))
        var positions: [UUID: CGPoint] = [:]
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var column = 0

        for id in members {
            let size = sizes[id] ?? CGSize(width: nodeWidth, height: estimateHeight(columnCount: 1))
            positions[id] = CGPoint(x: currentX, y: currentY)
            currentX += size.width + horizontalGap
            rowHeight = max(rowHeight, size.height)
            column += 1
            if column >= columns {
                column = 0
                currentX = 0
                currentY += rowHeight + verticalGap
                rowHeight = 0
            }
        }

        let width = members.map { (positions[$0]?.x ?? 0) + (sizes[$0]?.width ?? nodeWidth) }.max() ?? 0
        let height = members.map { (positions[$0]?.y ?? 0) + (sizes[$0]?.height ?? headerHeight) }.max() ?? 0
        return Block(positions: positions, size: CGSize(width: width, height: height))
    }

    private static func packBlocks(_ blockSizes: [CGSize]) -> [Int: CGPoint] {
        guard !blockSizes.isEmpty else { return [:] }

        let totalArea = blockSizes.reduce(0) { $0 + $1.width * $1.height }
        let widest = blockSizes.map(\.width).max() ?? 0
        let targetWidth = max(widest, sqrt(totalArea * 1.6))
        let order = blockSizes.indices.sorted { blockSizes[$0].height > blockSizes[$1].height }

        var placements: [Int: CGPoint] = [:]
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var shelfHeight: CGFloat = 0
        for index in order {
            let size = blockSizes[index]
            if currentX > 0, currentX + size.width > targetWidth {
                currentX = 0
                currentY += shelfHeight + blockGap
                shelfHeight = 0
            }
            placements[index] = CGPoint(x: currentX, y: currentY)
            currentX += size.width + blockGap
            shelfHeight = max(shelfHeight, size.height)
        }
        return placements
    }

    private static func composeCenters(
        blocks: [Block],
        placements: [Int: CGPoint],
        sizes: [UUID: CGSize]
    ) -> [UUID: CGPoint] {
        let padding: CGFloat = 40
        var result: [UUID: CGPoint] = [:]
        for (index, block) in blocks.enumerated() {
            let origin = placements[index] ?? .zero
            for (id, topLeft) in block.positions {
                let size = sizes[id] ?? CGSize(width: nodeWidth, height: estimateHeight(columnCount: 1))
                result[id] = CGPoint(
                    x: padding + origin.x + topLeft.x + size.width / 2,
                    y: padding + origin.y + topLeft.y + size.height / 2
                )
            }
        }
        return result
    }
}
