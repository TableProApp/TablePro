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

internal enum SidebarLayout: String, CaseIterable, Sendable {
    case flat
    case tree
}

@MainActor @Observable
final class SharedSidebarState {
    @ObservationIgnored private let userDefaults: UserDefaults

    var redisKeyTreeViewModel: RedisKeyTreeViewModel?

    var selectedSidebarTab: SidebarTab {
        didSet {
            userDefaults.set(
                selectedSidebarTab.rawValue,
                forKey: SidebarPersistenceKey.selectedTab(connectionId: connectionId)
            )
        }
    }

    var sidebarLayout: SidebarLayout {
        didSet {
            userDefaults.set(
                sidebarLayout.rawValue,
                forKey: SidebarPersistenceKey.layout(connectionId: connectionId)
            )
        }
    }

    static var defaultLayout: SidebarLayout {
        get {
            defaultLayout(userDefaults: .standard)
        }
        set {
            setDefaultLayout(newValue, userDefaults: .standard)
        }
    }

    let connectionId: UUID

    init(connectionId: UUID, userDefaults: UserDefaults = .standard) {
        self.connectionId = connectionId
        self.userDefaults = userDefaults
        let key = SidebarPersistenceKey.selectedTab(connectionId: connectionId)
        if let raw = userDefaults.string(forKey: key),
           let tab = SidebarTab(rawValue: raw) {
            self.selectedSidebarTab = tab
        } else {
            self.selectedSidebarTab = .tables
        }
        let layoutKey = SidebarPersistenceKey.layout(connectionId: connectionId)
        if let raw = userDefaults.string(forKey: layoutKey),
           let layout = SidebarLayout(rawValue: raw) {
            self.sidebarLayout = layout
        } else {
            self.sidebarLayout = SharedSidebarState.defaultLayout(userDefaults: userDefaults)
        }
    }

    /// Default init for previews and tests
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.connectionId = UUID()
        self.selectedSidebarTab = .tables
        self.sidebarLayout = .flat
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

    static func defaultLayout(userDefaults: UserDefaults) -> SidebarLayout {
        guard let raw = userDefaults.string(forKey: SidebarPersistenceKey.defaultLayout),
              let layout = SidebarLayout(rawValue: raw) else {
            return .flat
        }
        return layout
    }

    static func setDefaultLayout(_ layout: SidebarLayout, userDefaults: UserDefaults) {
        userDefaults.set(layout.rawValue, forKey: SidebarPersistenceKey.defaultLayout)
    }
}
