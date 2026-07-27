import Foundation

public enum ForeignKeyTopologicalSort {
    public static func orderedNames(
        _ names: [String],
        foreignKeysByTable: [String: [PluginForeignKeyInfo]]
    ) -> [String] {
        let nameSet = Set(names)
        var indegree: [String: Int] = [:]
        var children: [String: Set<String>] = [:]
        for name in names { indegree[name] = 0 }

        for name in names {
            var seenParents: Set<String> = []
            for fk in foreignKeysByTable[name] ?? [] where fk.referencedTable != name {
                guard nameSet.contains(fk.referencedTable),
                      !seenParents.contains(fk.referencedTable) else { continue }
                seenParents.insert(fk.referencedTable)
                children[fk.referencedTable, default: []].insert(name)
                indegree[name, default: 0] += 1
            }
        }

        var queue = names.filter { (indegree[$0] ?? 0) == 0 }.sorted()
        var ordered: [String] = []
        while !queue.isEmpty {
            let head = queue.removeFirst()
            ordered.append(head)
            for child in (children[head] ?? []).sorted() {
                indegree[child] = (indegree[child] ?? 0) - 1
                if indegree[child] == 0 {
                    queue.append(child)
                }
            }
        }

        guard ordered.count < names.count else { return ordered }
        let placed = Set(ordered)
        return ordered + names.filter { !placed.contains($0) }.sorted()
    }
}
