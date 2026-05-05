//
//  SettingsTab.swift
//  TablePro
//

import Foundation

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case appearance
    case editor
    case keyboard
    case ai
    case terminal
    case mcp
    case plugins
    case account

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general: return String(localized: "General")
        case .appearance: return String(localized: "Appearance")
        case .editor: return String(localized: "Editor")
        case .keyboard: return String(localized: "Keyboard")
        case .ai: return String(localized: "AI")
        case .terminal: return String(localized: "Terminal")
        case .mcp: return String(localized: "Integrations")
        case .plugins: return String(localized: "Plugins")
        case .account: return String(localized: "Account")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .editor: return "doc.text"
        case .keyboard: return "keyboard"
        case .ai: return "sparkles"
        case .terminal: return "terminal"
        case .mcp: return "network"
        case .plugins: return "puzzlepiece.extension"
        case .account: return "person.crop.circle"
        }
    }

    var searchKeywords: [String] {
        switch self {
        case .general:
            return ["startup", "language", "timeout", "updates", "tabs", "preview", "history", "privacy", "analytics"]
        case .appearance:
            return ["theme", "color", "dark", "light", "appearance", "font"]
        case .editor:
            return ["sql", "json", "viewer", "data grid", "vim", "tab width", "line numbers", "wrap", "uppercase"]
        case .keyboard:
            return ["shortcut", "hotkey", "keybinding", "keystroke"]
        case .ai:
            return ["openai", "anthropic", "claude", "copilot", "completion", "suggestion", "model", "api key"]
        case .terminal:
            return ["terminal", "console", "cli", "shell", "font"]
        case .mcp:
            return ["integration", "mcp", "server", "claude", "agent", "automation"]
        case .plugins:
            return ["plugin", "driver", "marketplace", "extension", "installed", "browse"]
        case .account:
            return ["license", "sync", "icloud", "linked", "folders", "subscription"]
        }
    }
}
