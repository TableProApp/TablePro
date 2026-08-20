import Foundation

enum ERClusterAnalyzer {
    static func assignClusters(
        nodes: [ERTableNode],
        edges: [EREdge],
        nodeIndex: [String: UUID]
    ) -> [UUID: Int] {
        guard !nodes.isEmpty else { return [:] }

        var parent: [UUID: UUID] = [:]
        var rank: [UUID: Int] = [:]
        for node in nodes {
            parent[node.id] = node.id
            rank[node.id] = 0
        }

        func find(_ start: UUID) -> UUID {
            var root = start
            while let next = parent[root], next != root { root = next }
            var current = start
            while let next = parent[current], next != root {
                parent[current] = root
                current = next
            }
            return root
        }

        func union(_ lhs: UUID, _ rhs: UUID) {
            let rootLhs = find(lhs)
            let rootRhs = find(rhs)
            guard rootLhs != rootRhs else { return }
            let rankLhs = rank[rootLhs] ?? 0
            let rankRhs = rank[rootRhs] ?? 0
            if rankLhs < rankRhs {
                parent[rootLhs] = rootRhs
            } else if rankLhs > rankRhs {
                parent[rootRhs] = rootLhs
            } else {
                parent[rootRhs] = rootLhs
                rank[rootLhs] = rankLhs + 1
            }
        }

        for edge in edges {
            guard let from = nodeIndex[edge.fromTable],
                  let to = nodeIndex[edge.toTable],
                  from != to
            else { continue }
            union(from, to)
        }

        var members: [UUID: [UUID]] = [:]
        for node in nodes {
            members[find(node.id), default: []].append(node.id)
        }

        let nameById = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.tableName) })
        let multiNodeComponents = members.values.filter { $0.count >= 2 }
        let ordered = multiNodeComponents.sorted { lhs, rhs in
            let lhsKey = lhs.compactMap { nameById[$0] }.min() ?? ""
            let rhsKey = rhs.compactMap { nameById[$0] }.min() ?? ""
            return lhsKey < rhsKey
        }

        var result: [UUID: Int] = [:]
        for (index, component) in ordered.enumerated() {
            for member in component { result[member] = index }
        }
        return result
    }
}
