//
//  SettingsNavigation.swift
//  TablePro
//

import Foundation

// Pure model of the Settings window's sidebar: the ordered sections, the rows in each, and the
// search index. No AppKit, SwiftUI or storage, so it unit-tests without a host. The window shell
// and the deep-link layer read this; they never hardcode the order themselves.
enum SettingsSectionID: String, CaseIterable, Sendable {
    case app
    case integrations
    case accountData
}

struct SettingsSection: Equatable, Sendable {
    let id: SettingsSectionID
    let panes: [SettingsPane]
}

enum SettingsNavigation {
    static let sections: [SettingsSection] = [
        SettingsSection(id: .app, panes: [.general, .sidebar, .connections, .appearance, .editor, .data, .keyboard, .notifications]),
        SettingsSection(id: .integrations, panes: [.ai, .mcp, .plugins]),
        SettingsSection(id: .accountData, panes: [.profiles, .sync, .account]),
    ]

    // The sidebar order, flattened. A permutation of SettingsPane.allCases: every pane once.
    static let orderedPanes: [SettingsPane] = sections.flatMap(\.panes)

    static let defaultPane: SettingsPane = .general

    // The deep-link and last-used-pane vocabulary stays SettingsPane.urlIdentifier / rawValue.
    static func pane(forURLIdentifier identifier: String) -> SettingsPane? {
        SettingsPane(urlIdentifier: identifier)
    }

    // Panes whose title or keywords contain every whitespace-split term of the query, in sidebar
    // order. An empty query returns the full order.
    static func panes(matching query: String) -> [SettingsPane] {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return orderedPanes }
        return orderedPanes.filter { pane in
            let haystack = ([pane.title] + pane.searchKeywords).joined(separator: " ").lowercased()
            return terms.allSatisfy(haystack.contains)
        }
    }
}

extension SettingsPane {
    // Terms that should match a pane in the sidebar search beyond its visible title. Kept here, not
    // in the pane enum, because they are a search concern, not the pane's identity.
    var searchKeywords: [String] {
        switch self {
        case .general: ["language", "startup", "privacy", "analytics", "reset", "command line", "cli", "update", "linked folders", "trusted"]
        case .sidebar: ["sidebar", "tabs", "preview tabs", "object icons", "object comments", "row size", "layout", "partitions", "system databases", "recent tables"]
        case .connections: ["connection", "recent connections", "health check", "query timeout", "timeout"]
        case .appearance: ["theme", "dark", "light", "color", "appearance mode"]
        case .editor: ["font", "sql", "format", "formatter", "indent", "gutter", "code"]
        case .data: ["grid", "results", "rows", "pagination", "history", "rewind", "null", "page size"]
        case .keyboard: ["shortcut", "shortcuts", "key", "binding", "hotkey"]
        case .notifications: ["alert", "notify", "badge"]
        case .ai: ["assistant", "model", "provider", "apple intelligence", "slash command", "agent"]
        case .mcp: ["server", "token", "client", "integration", "port"]
        case .plugins: ["extension", "driver", "module", "install"]
        case .profiles: ["credential", "ssh", "password", "profile", "bastion"]
        case .sync: ["icloud", "backup", "device"]
        case .account: ["license", "plan", "subscription", "team", "pro", "sign in"]
        }
    }
}
