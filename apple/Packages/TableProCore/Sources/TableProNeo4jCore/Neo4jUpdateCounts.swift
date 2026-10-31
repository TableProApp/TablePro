import Foundation

/// The update counters a statement's summary reports, in the order Neo4j lists them.
public struct Neo4jUpdateCounts: Equatable, Sendable {
    public enum Counter: String, CaseIterable, Sendable {
        case nodesCreated = "nodes-created"
        case nodesDeleted = "nodes-deleted"
        case relationshipsCreated = "relationships-created"
        case relationshipsDeleted = "relationships-deleted"
        case propertiesSet = "properties-set"
        case labelsAdded = "labels-added"
        case labelsRemoved = "labels-removed"
        case indexesAdded = "indexes-added"
        case indexesRemoved = "indexes-removed"
        case constraintsAdded = "constraints-added"
        case constraintsRemoved = "constraints-removed"
        case systemUpdates = "system-updates"
    }

    /// Every counter above zero.
    public let counters: [(counter: Counter, count: Int)]

    public init(summary: [String: PackStreamValue]) {
        let stats = summary["stats"]?.mapValue ?? [:]
        counters = Counter.allCases.compactMap { counter in
            let count = Int(stats[counter.rawValue]?.intValue ?? 0)
            return count > 0 ? (counter, count) : nil
        }
    }

    public func count(_ counter: Counter) -> Int {
        counters.first { $0.counter == counter }?.count ?? 0
    }

    /// Nodes and relationships created or deleted. A property or label change is not counted:
    /// its counter says how many values changed, not how many entities.
    public var entitiesChanged: Int {
        [.nodesCreated, .nodesDeleted, .relationshipsCreated, .relationshipsDeleted].reduce(0) { $0 + count($1) }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.counters.elementsEqual(rhs.counters) { $0.counter == $1.counter && $0.count == $1.count }
    }
}
