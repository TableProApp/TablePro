//
//  AppSettingsCategory.swift
//  TablePro
//

import Foundation

// One home for the ids every settings category syncs under. They used to be spelled out in four
// lists nothing forced to agree, and a category missing from one stayed dirty forever without ever
// reaching the other Mac.
internal enum AppSettingsCategory {
    internal static let general = "general"
    internal static let appearance = "appearance"
    internal static let editor = "editor"
    internal static let dataGrid = "dataGrid"
    internal static let history = "history"
    internal static let tabs = "tabs"
    internal static let keyboard = "keyboard"
    internal static let ai = "ai"
    internal static let notifications = "notifications"
    internal static let appearanceMode = "appearanceMode"

    // `sync` holds the switch that turns syncing on, `mcp` a port and server setup for one machine,
    // and `appearanceMode` the Auto, Light or Dark choice each Mac makes for itself.
    internal static let deviceLocal: Set<String> = ["sync", "mcp", appearanceMode]

    internal static let synced: [String] = [
        general, appearance, editor, dataGrid, history, tabs, keyboard, ai, notifications
    ]
}
