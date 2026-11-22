import Foundation

// The rawValue is the stored last-used pane, so it never follows a title.
enum SettingsPane: String, CaseIterable, Sendable {
    case general, sidebar, connections, appearance, editor, data, keyboard, profiles, notifications, ai, mcp, plugins, sync, account

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .sidebar: String(localized: "Sidebar & Tabs")
        case .connections: String(localized: "Connections")
        case .appearance: String(localized: "Appearance")
        case .editor: String(localized: "Editor")
        case .data: String(localized: "Data")
        case .keyboard: String(localized: "Keyboard")
        case .profiles: String(localized: "Profiles")
        case .notifications: String(localized: "Notifications")
        case .ai: String(localized: "AI")
        case .mcp: "MCP"
        case .plugins: String(localized: "Extensions")
        case .sync: String(localized: "iCloud Sync")
        case .account: String(localized: "Account")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .sidebar: "sidebar.left"
        case .connections: "cylinder.split.1x2"
        case .appearance: "circle.lefthalf.filled"
        case .editor: "square.and.pencil"
        case .data: "tablecells"
        case .keyboard: "keyboard"
        case .profiles: "person.badge.key"
        case .notifications: "bell"
        case .ai: "sparkles"
        case .mcp: "point.3.connected.trianglepath.dotted"
        case .plugins: "puzzlepiece.extension"
        case .sync: "icloud"
        case .account: "person.crop.circle"
        }
    }
}
