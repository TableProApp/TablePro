//
//  DatabaseConnection+SafeMode.swift
//  TablePro
//

import Foundation

extension DatabaseConnection {
    /// The Safe Mode level in force: the user's own level, raised to Read-Only when the
    /// connection cannot be written to.
    ///
    /// Every reader asks this one property, so a connection that cannot be written to reads as
    /// Read-Only in the grid, the toolbar, the execution gate, MCP and scripting alike. Only the
    /// places that persist or edit the user's choice read `preferredSafeModeLevel`. Assigning
    /// sets the user's choice.
    var safeModeLevel: SafeModeLevel {
        get { readOnlyEnforcement == nil ? preferredSafeModeLevel : .readOnly }
        set { preferredSafeModeLevel = newValue }
    }

    var readOnlyEnforcement: ReadOnlyEnforcement? {
        ReadOnlyEnforcement.resolve(
            isEngineReadOnly: PluginMetadataRegistry.shared.snapshot(for: type)?.capabilities.isEngineReadOnly ?? false,
            opensRemoteDatabaseFile: opensRemoteDatabaseFile
        )
    }
}
