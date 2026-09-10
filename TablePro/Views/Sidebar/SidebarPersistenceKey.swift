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

    static func recentsExpanded(connectionId: UUID) -> String {
        "sidebar.\(connectionId.uuidString).recents.expanded"
    }

    static func selectedTab(connectionId: UUID) -> String {
        "sidebar.selectedTab.\(connectionId.uuidString)"
    }

    static func selectedFavorite(connectionId: UUID) -> String {
        "sidebar.selectedFavoriteNodeId.\(connectionId.uuidString)"
    }

    static func favoriteDatabaseEnvironmentFilter(connectionId: UUID) -> String {
        "sidebar.favoriteDatabaseEnvironmentFilter.\(connectionId.uuidString)"
    }

    static let defaultLayout = "sidebar.defaultLayout"

    static func layout(connectionId: UUID) -> String {
        "sidebar.layout.\(connectionId.uuidString)"
    }

    static func expanded(connectionId: UUID, kind: SidebarObjectKind) -> String {
        "sidebar.\(connectionId.uuidString).\(kind.rawValue).expanded"
    }

    /// Every per-connection key this type can produce. A key added above and forgotten here outlives
    /// the connection it belongs to for the life of the install.
    static func all(connectionId: UUID) -> [String] {
        [
            tablesExpanded(connectionId: connectionId),
            redisKeysExpanded(connectionId: connectionId),
            recentsExpanded(connectionId: connectionId),
            selectedTab(connectionId: connectionId),
            selectedFavorite(connectionId: connectionId),
            favoriteDatabaseEnvironmentFilter(connectionId: connectionId),
            layout(connectionId: connectionId)
        ] + SidebarObjectKind.allCases.map { expanded(connectionId: connectionId, kind: $0) }
    }

    static func removeAll(
        connectionId: UUID,
        defaults: UserDefaults = AppStorageEnvironment.shared.defaults
    ) {
        for key in all(connectionId: connectionId) {
            defaults.removeObject(forKey: key)
        }
    }
}
