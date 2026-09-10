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

    /// The ordering, and the tables a dependency cycle left it unable to place. A caller that
    /// writes a script the order has to be right for reads `unorderedByCycle` to say so, because
    /// `tables` alone cannot distinguish a parent-first order from a partial one.
    public struct Ordering: Sendable {
        public let tables: [Table]
        public let unorderedByCycle: [Table]

        public init(tables: [Table], unorderedByCycle: [Table]) {
            self.tables = tables
            self.unorderedByCycle = unorderedByCycle
        }
    }

    /// Orders `tables` so a parent precedes every child that references it. Identity is
    /// `Table.identifier` throughout: `foreignKeysByTable` is keyed by it, and a foreign key
    /// that names no `referencedSchema` points inside the referencing table's own schema.
    /// Tables caught in a cycle keep the order they were given, and everything outside the cycle
    /// is still ordered around them, so the result holds every distinct input table exactly once.
    public static func ordered(
        _ tables: [Table],
        foreignKeysByTable: [String: [PluginForeignKeyInfo]],
        childrenFirst: Bool = false
    ) -> [Table] {
        order(tables, foreignKeysByTable: foreignKeysByTable, childrenFirst: childrenFirst).tables
    }

    /// `ordered`, plus the tables that sit inside a foreign key cycle. Tables are grouped into
    /// strongly connected components and the component graph is ordered, so a table that merely
    /// descends from a cycle still lands after it and is not reported as part of it. Only a
    /// component holding more than one table is unorderable, and its members keep their input order.
    public static func order(
        _ tables: [Table],
        foreignKeysByTable: [String: [PluginForeignKeyInfo]],
        childrenFirst: Bool = false
    ) -> Ordering {
        let nodes = distinct(tables)
        guard nodes.count > 1 else { return Ordering(tables: nodes, unorderedByCycle: []) }

        let byIdentifier = Dictionary(nodes.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [String: Set<String>] = [:]

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
            }
        }

        let components = stronglyConnectedComponents(of: nodes, children: children)
        let componentOf = Dictionary(
            components.enumerated().flatMap { index, members in members.map { ($0, index) } },
            uniquingKeysWith: { first, _ in first })

        var componentIndegree = [Int](repeating: 0, count: components.count)
        var componentChildren: [Set<Int>] = Array(repeating: [], count: components.count)
        for (parent, kids) in children {
            guard let parentComponent = componentOf[parent] else { continue }
            for kid in kids {
                guard let kidComponent = componentOf[kid],
                      kidComponent != parentComponent,
                      componentChildren[parentComponent].insert(kidComponent).inserted else { continue }
                componentIndegree[kidComponent] += 1
            }
        }

        let componentKey = components.map { $0.min() ?? "" }
        var queue = (0 ..< components.count)
            .filter { componentIndegree[$0] == 0 }
            .sorted { componentKey[$0] < componentKey[$1] }
        var placed: [String] = []
        var unordered: [String] = []
        while !queue.isEmpty {
            let head = queue.removeFirst()
            placed.append(contentsOf: components[head])
            if components[head].count > 1 {
                unordered.append(contentsOf: components[head])
            }
            for child in componentChildren[head].sorted(by: { componentKey[$0] < componentKey[$1] }) {
                componentIndegree[child] -= 1
                if componentIndegree[child] == 0 {
                    queue.append(child)
                }
            }
        }

        let resolved = placed.compactMap { byIdentifier[$0] }
        return Ordering(
            tables: childrenFirst ? resolved.reversed() : resolved,
            unorderedByCycle: unordered.compactMap { byIdentifier[$0] }
        )
    }

    /// Tarjan, iterative so a deep dependency chain cannot overflow the stack. Members come back
    /// in the order `nodes` gave them, and a component of more than one table is a cycle: nothing
    /// in it can be written before the rest. A table that merely descends from one is its own
    /// component and still lands after it, which is why the two are reported separately.
    private static func stronglyConnectedComponents(
        of nodes: [Table],
        children: [String: Set<String>]
    ) -> [[String]] {
        let order = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.identifier, $0) })
        var index: [String: Int] = [:]
        var lowLink: [String: Int] = [:]
        var onStack: Set<String> = []
        var stack: [String] = []
        var nextIndex = 0
        var components: [[String]] = []

        for root in nodes.map({ $0.identifier }) where index[root] == nil {
            var work: [(node: String, next: Int, neighbours: [String])] = [
                (root, 0, (children[root] ?? []).sorted())
            ]
            index[root] = nextIndex
            lowLink[root] = nextIndex
            nextIndex += 1
            stack.append(root)
            onStack.insert(root)

            while let frame = work.last {
                if frame.next < frame.neighbours.count {
                    work[work.count - 1].next += 1
                    let neighbour = frame.neighbours[frame.next]
                    if index[neighbour] == nil {
                        index[neighbour] = nextIndex
                        lowLink[neighbour] = nextIndex
                        nextIndex += 1
                        stack.append(neighbour)
                        onStack.insert(neighbour)
                        work.append((neighbour, 0, (children[neighbour] ?? []).sorted()))
                    } else if onStack.contains(neighbour) {
                        lowLink[frame.node] = min(lowLink[frame.node] ?? 0, index[neighbour] ?? 0)
                    }
                    continue
                }

                work.removeLast()
                if let parent = work.last?.node {
                    lowLink[parent] = min(lowLink[parent] ?? 0, lowLink[frame.node] ?? 0)
                }
                guard lowLink[frame.node] == index[frame.node] else { continue }
                var members: [String] = []
                while let member = stack.popLast() {
                    onStack.remove(member)
                    members.append(member)
                    if member == frame.node { break }
                }
                components.append(members.sorted { (order[$0] ?? 0) < (order[$1] ?? 0) })
            }
        }

        return components
    }

    private static func distinct(_ tables: [Table]) -> [Table] {
        var seen: Set<String> = []
        return tables.filter { seen.insert($0.identifier).inserted }
    }
}
