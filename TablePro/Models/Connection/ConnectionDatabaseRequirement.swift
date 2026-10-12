//
//  ConnectionDatabaseRequirement.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Whether a connection of this type has to carry a database name to be usable.
///
/// One owner, because two answers drift. The connection form refuses to save without a value when
/// this is true, and the catalog adoption refuses to empty the field for the same reason: a
/// dropped database leaves nothing to put there, and a type that requires one would be left
/// failing its own validation with nothing on screen saying why.
@MainActor
internal enum ConnectionDatabaseRequirement {
    /// Whether the form renders the built-in Database field at all. A driver opts out through
    /// `hidesBuiltInDatabase` when it names its container some other way, or has none.
    internal static func showsBuiltInField(for type: DatabaseType) -> Bool {
        let hidden = PluginMetadataRegistry.shared.snapshot(for: type)?.connection.hidesBuiltInDatabase ?? false
        switch PluginManager.shared.connectionMode(for: type) {
        case .fileBased:
            return false
        case .apiOnly:
            return PluginManager.shared.supportsDatabaseSwitching(for: type) && !hidden
        default:
            return !hidden
        }
    }

    /// Never require a value the form does not render. A file-based connection stores its path in
    /// `database` and renders it as the Database File field.
    internal static func requiresValue(for type: DatabaseType) -> Bool {
        let mode = PluginManager.shared.connectionMode(for: type)
        return mode == .fileBased || (mode == .apiOnly && showsBuiltInField(for: type))
    }
}
