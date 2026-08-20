//
//  AppSettingsCategory.swift
//  TablePro
//

import Foundation

/// The identity every settings category syncs under, in one place.
///
/// These strings used to be spelled out separately in four lists that nothing forced to agree: the
/// `markDirty` call in each `didSet`, the seed list that runs when sync is switched on, and the
/// encode and decode switches. A category present in the first and missing from the others is
/// marked dirty forever, never encodes, never clears, and never reaches the user's other Mac, with
/// nothing anywhere reporting a problem. `mcp` and `sync` were in exactly that state, which is why
/// they are now named as device-local rather than left to look like an oversight.
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

    /// Never synced, and deliberately so. `sync` carries the switch that turns syncing on, and
    /// `mcp` carries a port and local server configuration that belongs to one machine.
    internal static let deviceLocal: Set<String> = ["sync", "mcp"]

    internal static let synced: [String] = [
        general, appearance, editor, dataGrid, history, tabs, keyboard, ai, notifications
    ]
}
