//
//  ScriptingKeys.swift
//  TablePro
//

import Foundation

/// The `cocoa key` strings the scripting dictionary binds each record property to.
///
/// A record result is an `NSDictionary` whose keys have to match `TablePro.sdef` exactly, and a key
/// that does not match is not an error: Cocoa returns the record with that property missing, or
/// fails the whole reply with `errAEEventNotHandled` and no diagnostic anywhere. They are named once
/// here so the encoder and `ScriptingDictionaryTests` read the same list rather than two copies of
/// the same spelling.
internal enum ScriptingKeys {
    internal enum QueryResult {
        internal static let columns = "scriptColumns"
        internal static let rows = "scriptRows"
        internal static let rowCount = "scriptRowCount"
        internal static let rowsAffected = "scriptRowsAffected"
        internal static let truncated = "scriptTruncated"
        internal static let executionTime = "scriptExecutionTime"
        internal static let statusMessage = "scriptStatusMessage"

        internal static let all = [
            columns, rows, rowCount, rowsAffected, truncated, executionTime, statusMessage
        ]
    }

    internal enum ResultRow {
        internal static let values = "scriptValues"

        internal static let all = [values]
    }

    internal enum Parameter {
        internal static let connection = "ScriptConnectionArgument"
        internal static let database = "ScriptDatabaseArgument"
        internal static let schema = "ScriptSchemaArgument"
        internal static let rowLimit = "ScriptRowLimitArgument"
        internal static let timeout = "ScriptTimeoutArgument"
    }

    internal enum Element {
        internal static let connections = "scriptConnections"
        internal static let tabs = "scriptTabs"
    }
}
