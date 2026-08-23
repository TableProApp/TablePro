import Foundation

public enum ForeignKeyTopologicalSort {
    /// One node of the dependency graph. Two tables that share a name in different schemas are
    /// two nodes, so no ordering can collapse them into one.
    public struct Table: Hashable, Sendable {
        public let name: String
        public let schema: String?

        public init(name: String, schema: String? = nil) {
            self.name = name
            self.schema = (schema?.isEmpty ?? true) ? nil : schema
        }

        public var identifier: String {
            guard let schema else { return name }
            return "\(schema).\(name)"
        }
    }

    /// Orders `tables` so a parent precedes every child that references it. Identity is
    /// `Table.identifier` throughout: `foreignKeysByTable` is keyed by it, and a foreign key
    /// that names no `referencedSchema` points inside the referencing table's own schema.
    /// A dependency cycle falls back to the tables the traversal could not place, in identifier
    /// order, so the result holds every distinct input table exactly once.
    public static func ordered(
        _ tables: [Table],
        foreignKeysByTable: [String: [PluginForeignKeyInfo]],
        childrenFirst: Bool = false
    ) -> [Table] {
        let nodes = distinct(tables)
        guard nodes.count > 1 else { return nodes }

        let byIdentifier = Dictionary(nodes.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        var indegree: [String: Int] = [:]
        var children: [String: Set<String>] = [:]
        for node in nodes { indegree[node.identifier] = 0 }

        for node in nodes {
            let identifier = node.identifier
            var seenParents: Set<String> = []
            for foreignKey in foreignKeysByTable[identifier] ?? [] {
                let parent = Table(
                    name: foreignKey.referencedTable,
                    schema: foreignKey.referencedSchema ?? node.schema
                ).identifier
                guard parent != identifier,
                      byIdentifier[parent] != nil,
                      seenParents.insert(parent).inserted else { continue }
                children[parent, default: []].insert(identifier)
                indegree[identifier, default: 0] += 1
            }
        }

        var queue = nodes.map { $0.identifier }.filter { (indegree[$0] ?? 0) == 0 }.sorted()
        var placed: [String] = []
        while !queue.isEmpty {
            let head = queue.removeFirst()
            placed.append(head)
            for child in (children[head] ?? []).sorted() {
                indegree[child] = (indegree[child] ?? 0) - 1
                if indegree[child] == 0 {
                    queue.append(child)
                }
            }
        }

        if placed.count < nodes.count {
            let settled = Set(placed)
            placed += nodes.map { $0.identifier }.filter { !settled.contains($0) }.sorted()
        }

        let resolved = placed.compactMap { byIdentifier[$0] }
        return childrenFirst ? resolved.reversed() : resolved
    }

    private static func distinct(_ tables: [Table]) -> [Table] {
        var seen: Set<String> = []
        return tables.filter { seen.insert($0.identifier).inserted }
    }
}
