//
//  SettingsView.swift
//  TablePro
//

import SwiftUI

enum SettingsPane: String, CaseIterable {
    case general, appearance, editor, data, keyboard, profiles, notifications, ai, mcp, plugins, sync, account

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .appearance: String(localized: "Appearance")
        case .editor: String(localized: "Editor")
        case .data: String(localized: "Data")
        case .keyboard: String(localized: "Keyboard")
        case .profiles: String(localized: "Profiles")
        case .notifications: String(localized: "Notifications")
        case .ai: String(localized: "AI")
        case .mcp: String(localized: "Integrations")
        case .plugins: String(localized: "Plugins")
        case .sync: String(localized: "Sync")
        /// The stored rawValue stays "account": it is the tab item identifier and the pane the
        /// window restores, so renaming it would silently reset everyone's last-used pane.
        case .account: String(localized: "License")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .editor: "doc.text"
        case .data: "tablecells"
        case .keyboard: "keyboard"
        case .profiles: "person.badge.key"
        case .notifications: "bell"
        case .ai: "sparkles"
        case .mcp: "network"
        case .plugins: "puzzlepiece.extension"
        case .sync: "arrow.triangle.2.circlepath"
        case .account: "key.fill"
        }
    }
}
