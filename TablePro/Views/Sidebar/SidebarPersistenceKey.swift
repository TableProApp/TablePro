import Foundation

enum SidebarPersistenceKey {
    static let isTablesExpanded = "sidebar.isTablesExpanded"
    static let isRedisKeysExpanded = "sidebar.isRedisKeysExpanded"

    static func selectedTab(connectionId: UUID) -> String {
        "sidebar.selectedTab.\(connectionId.uuidString)"
    }
}
