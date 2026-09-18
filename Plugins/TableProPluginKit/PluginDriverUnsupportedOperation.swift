//
//  PluginDriverUnsupportedOperation.swift
//  TableProPluginKit
//

import Foundation

/// A rename the engine has no operation for.
///
/// The three are separate because they are separate facts about an engine, and one message for
/// all of them would be wrong for most of it. MySQL renames a table and has had no way to rename
/// a database since 5.1.23; Oracle renames a table while its "databases" here are users, which it
/// cannot rename at all; Cassandra can rename neither, because a CQL `ALTER TABLE ... RENAME`
/// renames primary key columns.
///
/// A driver reaches these only through a default implementation. Where the engine can do the
/// work, its `DriverPlugin` says so and the menu never offers what would throw.
public enum PluginDriverUnsupportedOperation: Error, LocalizedError, Sendable {
    case renameTable
    case renameDatabase
    case renameSchema

    public var errorDescription: String? {
        switch self {
        case .renameTable:
            return String(localized: "This database cannot rename a table")
        case .renameDatabase:
            return String(localized: "This database cannot be renamed")
        case .renameSchema:
            return String(localized: "This database cannot rename a schema")
        }
    }
}
