import Foundation

protocol ConnectionIdentifiable {
    var connectionId: UUID { get }
}

enum TokenPermissionFilter {
    static let overfetchMultiplier = 3
    private static let maxRoundTrips = 2

    static func filter<T: ConnectionIdentifiable>(_ items: [T], by access: ConnectionAccess) -> [T] {
        switch access {
        case .all:
            return items
        case .limited(let ids):
            return items.filter { ids.contains($0.connectionId) }
        }
    }

    static func fetchFiltered<T: ConnectionIdentifiable>(
        access: ConnectionAccess,
        limit: Int,
        fetch: (Int, Int) async throws -> [T]
    ) async throws -> [T] {
        if case .all = access {
            let items = try await fetch(limit, 0)
            return Array(items.prefix(limit))
        }

        guard limit > 0 else { return [] }

        let fetchLimit = limit * overfetchMultiplier
        var collected: [T] = []
        var offset = 0

        for _ in 0..<maxRoundTrips {
            let raw = try await fetch(fetchLimit, offset)
            let filtered = filter(raw, by: access)
            collected.append(contentsOf: filtered)
            if collected.count >= limit { break }
            if raw.count < fetchLimit { break }
            offset += fetchLimit
        }

        return Array(collected.prefix(limit))
    }
}
