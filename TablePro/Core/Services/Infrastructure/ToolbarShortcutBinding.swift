//
//  ToolbarShortcutBinding.swift
//  TablePro
//

import Foundation

/// What a toolbar item says about the keyboard shortcut that runs it.
///
/// The description is the wording, which for some items follows the connection ("Open Keyspace" on
/// Cassandra, "Preview MQL" on MongoDB); the shortcut resolves to the key through the user's
/// keyboard settings and is never spelled out as a literal, so the toolbar cannot drift from the
/// menu bar the way it did while both held their own copy.
internal struct ToolbarShortcutBinding: Equatable {
    internal let shortcut: ShortcutAction
    internal var description: String
}
