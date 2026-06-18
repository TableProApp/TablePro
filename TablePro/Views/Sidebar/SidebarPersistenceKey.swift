import Foundation

enum SidebarPersistenceKey {
    static let legacyTablesExpanded = "sidebar.isTablesExpanded"
    static let legacyRedisKeysExpanded = "sidebar.isRedisKeysExpanded"

    static func tablesExpanded(connectionId: UUID) -> String {
        "sidebar.\(connectionId.uuidString).tables.expanded"
    }

    static func redisKeysExpanded(connectionId: UUID) -> String {
        "sidebar.\(connectionId.uuidString).redisKeys.expanded"
    }

    static func selectedTab(connectionId: UUID) -> String {
        "sidebar.selectedTab.\(connectionId.uuidString)"
    }

    static func selectedFavorite(connectionId: UUID) -> String {
        "sidebar.selectedFavoriteNodeId.\(connectionId.uuidString)"
    }

    static let defaultLayout = "sidebar.defaultLayout"

    static func layout(connectionId: UUID) -> String {
        "sidebar.layout.\(connectionId.uuidString)"
    }

    static func expanded(connectionId: UUID, kind: SidebarObjectKind) -> String {
        "sidebar.\(connectionId.uuidString).\(kind.rawValue).expanded"
    }
}
