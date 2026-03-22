//
//  SharedSidebarState.swift
//  TablePro
//
//  Shared sidebar state (selection + search + tab) for cross-tab synchronization.
//  One instance per connection, shared across all native macOS tabs.
//

import Foundation

/// Which sidebar tab is active
internal enum SidebarTab: String, CaseIterable {
    case tables
    case favorites
}

@MainActor @Observable
final class SharedSidebarState {
    var selectedTables: Set<TableInfo> = []
    var searchText: String = ""
    var redisKeyTreeViewModel: RedisKeyTreeViewModel?

    var selectedSidebarTab: SidebarTab {
        didSet {
            UserDefaults.standard.set(
                selectedSidebarTab.rawValue,
                forKey: "sidebar.selectedTab.\(connectionId.uuidString)"
            )
        }
    }

    let connectionId: UUID

    private init(connectionId: UUID) {
        self.connectionId = connectionId
        let key = "sidebar.selectedTab.\(connectionId.uuidString)"
        if let raw = UserDefaults.standard.string(forKey: key),
           let tab = SidebarTab(rawValue: raw) {
            self.selectedSidebarTab = tab
        } else {
            self.selectedSidebarTab = .tables
        }
    }

    /// Default init for previews and tests
    init() {
        self.connectionId = UUID()
        self.selectedSidebarTab = .tables
    }

    private static var registry: [UUID: SharedSidebarState] = [:]

    static func forConnection(_ id: UUID) -> SharedSidebarState {
        if let existing = registry[id] { return existing }
        let state = SharedSidebarState(connectionId: id)
        registry[id] = state
        return state
    }

    static func removeConnection(_ id: UUID) {
        registry.removeValue(forKey: id)
    }
}
