//
//  SettingsPane+URLIdentifier.swift
//  TablePro
//

import Foundation

/// The ids in `tablepro://settings/<id>` links. They are public and documented, so they never
/// follow a pane's title or rawValue.
internal extension SettingsPane {
    var urlIdentifier: String {
        switch self {
        case .general: "general"
        case .appearance: "appearance"
        case .editor: "editor"
        case .data: "data"
        case .keyboard: "keyboard"
        case .profiles: "profiles"
        case .notifications: "notifications"
        case .ai: "ai"
        case .mcp: "mcp"
        case .plugins: "plugins"
        case .sync: "sync"
        case .account: "license"
        }
    }

    init?(urlIdentifier: String) {
        switch urlIdentifier {
        case "general": self = .general
        case "appearance": self = .appearance
        case "editor": self = .editor
        case "data": self = .data
        case "keyboard": self = .keyboard
        case "profiles": self = .profiles
        case "notifications": self = .notifications
        case "ai": self = .ai
        case "mcp": self = .mcp
        case "plugins": self = .plugins
        case "sync": self = .sync
        case "license": self = .account
        default: return nil
        }
    }
}
