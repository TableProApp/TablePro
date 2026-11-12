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

    static func favoritesExpanded(connectionId: UUID) -> String {
        "sidebar.\(connectionId.uuidString).favorites.expanded"
    }

    /// The connection's own row in a tree that lists the saved connections above its databases.
    static func ownConnectionExpanded(connectionId: UUID) -> String {
        "sidebar.\(connectionId.uuidString).connection.expanded"
    }

    static func foldersExpanded(connectionId: UUID) -> String {
        "sidebar.\(connectionId.uuidString).folders.expanded"
    }

    static func temporaryExpanded(connectionId: UUID) -> String {
        "sidebar.\(connectionId.uuidString).temporary.expanded"
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

    // Built-in kinds only; a declared kind's state lives under `serverKindsExpanded`.
    static func expanded(connectionId: UUID, kind: SidebarObjectKind) -> String {
        "sidebar.\(connectionId.uuidString).\(kind.persistenceName).expanded"
    }

    // One key for every declared kind, since their ids are open-ended and `all` has to name each key.
    static func serverKindsExpanded(connectionId: UUID) -> String {
        "sidebar.\(connectionId.uuidString).serverKinds.expanded"
    }

    // A key missing here outlives its connection for the life of the install.
    static func all(connectionId: UUID) -> [String] {
        [
            tablesExpanded(connectionId: connectionId),
            redisKeysExpanded(connectionId: connectionId),
            recentsExpanded(connectionId: connectionId),
            favoritesExpanded(connectionId: connectionId),
            ownConnectionExpanded(connectionId: connectionId),
            foldersExpanded(connectionId: connectionId),
            temporaryExpanded(connectionId: connectionId),
            selectedTab(connectionId: connectionId),
            selectedFavorite(connectionId: connectionId),
            favoriteDatabaseEnvironmentFilter(connectionId: connectionId),
            layout(connectionId: connectionId),
            serverKindsExpanded(connectionId: connectionId)
        ] + SidebarObjectKind.builtIn.map { expanded(connectionId: connectionId, kind: $0) }
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
