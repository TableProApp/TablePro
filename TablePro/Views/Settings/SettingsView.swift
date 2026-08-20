//
//  SettingsView.swift
//  TablePro
//

import SwiftUI

enum SettingsPane: String, CaseIterable {
    case general, appearance, editor, data, keyboard, ai, mcp, plugins, account

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .appearance: String(localized: "Appearance")
        case .editor: String(localized: "Editor")
        case .data: String(localized: "Data")
        case .keyboard: String(localized: "Keyboard")
        case .ai: String(localized: "AI")
        case .mcp: String(localized: "Integrations")
        case .plugins: String(localized: "Plugins")
        case .account: String(localized: "Account")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .editor: "doc.text"
        case .data: "tablecells"
        case .keyboard: "keyboard"
        case .ai: "sparkles"
        case .mcp: "network"
        case .plugins: "puzzlepiece.extension"
        case .account: "person.crop.circle"
        }
    }
}
