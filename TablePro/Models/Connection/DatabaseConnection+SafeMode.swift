//
//  DatabaseConnection+SafeMode.swift
//  TablePro
//

import Foundation

extension DatabaseConnection {
    /// The Safe Mode level in force: the user's own level, raised to the connection's floor.
    ///
    /// Every reader asks this one property, so a connection that cannot be written to, or one a
    /// configuration profile holds at a minimum, reads the same in the grid, the toolbar, the
    /// execution gate, MCP and scripting alike. Only the places that persist or edit the user's
    /// choice read `preferredSafeModeLevel`. Assigning sets the user's choice.
    var safeModeLevel: SafeModeLevel {
        get { safeModeFloor?.raising(preferredSafeModeLevel) ?? preferredSafeModeLevel }
        set { preferredSafeModeLevel = newValue }
    }

    var safeModeFloor: SafeModeFloor? {
        SafeModeFloor.resolve(
            isEngineReadOnly: PluginMetadataRegistry.shared.snapshot(for: type)?.capabilities.isEngineReadOnly ?? false,
            opensRemoteDatabaseFile: opensRemoteDatabaseFile,
            managedMinimum: ManagedPolicyResolver.minimumSafeModeLevel(policy: ManagedPolicyReader.shared)
        )
    }
}
