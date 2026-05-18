//
//  SharedSidebarState.swift
//  TablePro
//
//  Connection-scoped sidebar state shared across all windows of the same
//  connection. Window-scoped state (table selection) lives in
//  `WindowSidebarState`.
//

import Foundation

/// Which sidebar tab is active
internal enum SidebarTab: String, CaseIterable {
    case tables
    case favorites
}

@MainActor @Observable
final class SharedSidebarState {
    var redisKeyTreeViewModel: RedisKeyTreeViewModel?

    var selectedSidebarTab: SidebarTab {
        didSet {
            UserDefaults.standard.set(
                selectedSidebarTab.rawValue,
                forKey: SidebarPersistenceKey.selectedTab(connectionId: connectionId)
            )
        }
    }

    let connectionId: UUID

    private init(connectionId: UUID) {
        self.connectionId = connectionId
        let key = SidebarPersistenceKey.selectedTab(connectionId: connectionId)
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
