import Foundation

// Published ids of tablepro://settings/<id> links, so they never follow a title or rawValue.
extension SettingsPane {
    var urlIdentifier: String {
        switch self {
        case .general: "general"
        case .sidebar: "sidebar"
        case .connections: "connections"
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
        guard let pane = Self.allCases.first(where: { $0.urlIdentifier == urlIdentifier }) else { return nil }
        self = pane
    }
}
