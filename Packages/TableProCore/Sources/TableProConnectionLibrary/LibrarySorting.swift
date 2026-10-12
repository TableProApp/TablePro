import Foundation

public enum LibrarySorting {
    public static func connectionPrecedes<Connection: LibraryConnectionRepresentable>(
        _ lhs: Connection,
        _ rhs: Connection,
        mode: LibrarySortMode,
        lastConnected: [UUID: Date]
    ) -> Bool {
        switch mode {
        case .manual:
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return namePrecedes(lhs.name, rhs.name, lhsId: lhs.id, rhsId: rhs.id)
        case .name:
            return namePrecedes(lhs.name, rhs.name, lhsId: lhs.id, rhsId: rhs.id)
        case .databaseType:
            let order = lhs.libraryTypeName.localizedStandardCompare(rhs.libraryTypeName)
            if order != .orderedSame { return order == .orderedAscending }
            return namePrecedes(lhs.name, rhs.name, lhsId: lhs.id, rhsId: rhs.id)
        case .lastConnected:
            switch (lastConnected[lhs.id], lastConnected[rhs.id]) {
            case let (left?, right?) where left != right:
                return left > right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return namePrecedes(lhs.name, rhs.name, lhsId: lhs.id, rhsId: rhs.id)
            }
        }
    }

    public static func groupPrecedes(
        _ lhs: LibraryGroupGraph.Entry,
        _ rhs: LibraryGroupGraph.Entry,
        mode: LibrarySortMode
    ) -> Bool {
        if mode == .manual, lhs.sortOrder != rhs.sortOrder {
            return lhs.sortOrder < rhs.sortOrder
        }
        return namePrecedes(lhs.name, rhs.name, lhsId: lhs.id, rhsId: rhs.id)
    }

    public static func sorted<Connection: LibraryConnectionRepresentable>(
        _ connections: [Connection],
        mode: LibrarySortMode,
        lastConnected: [UUID: Date] = [:]
    ) -> [Connection] {
        connections.sorted { connectionPrecedes($0, $1, mode: mode, lastConnected: lastConnected) }
    }

    private static func namePrecedes(_ lhs: String, _ rhs: String, lhsId: UUID, rhsId: UUID) -> Bool {
        let order = lhs.localizedStandardCompare(rhs)
        if order != .orderedSame { return order == .orderedAscending }
        return lhsId.uuidString < rhsId.uuidString
    }
}
