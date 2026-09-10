//
//  ContainerSwitchPlanner.swift
//  TablePro
//

import Foundation

/// One container switch, in the order it has to be applied.
internal enum ContainerSwitchStep: Equatable {
    case database(String)
    case schema(String)
}

/// Turns a link's database and schema segments into the switches an engine can actually perform.
///
/// A link names dimensions, not a single container. Choosing one of them and discarding the other
/// is what applied a database name as a schema on PostgreSQL, where `SET search_path` accepts a
/// name that does not exist and reports success.
internal enum ContainerSwitchPlanner {
    /// Ordered outermost first, because switching database can reset the schema: on an engine that
    /// reconnects to change database the schema comes back from the new session, so a schema
    /// applied first would be thrown away.
    internal static func plan(
        database: String?,
        schema: String?,
        switchable: [ContainerSwitchTarget]
    ) -> [ContainerSwitchStep] {
        var steps: [ContainerSwitchStep] = []

        if let database, !database.isEmpty {
            if switchable.contains(.database) || !switchable.contains(.schema) {
                /// An engine that reports no switchable container at all still keeps today's
                /// behaviour, which is to try the database. Redis browses a numbered database and
                /// declares neither dimension, so dropping the segment would break its links.
                steps.append(.database(database))
            } else if schema == nil {
                /// A schema-only engine has no database dimension, so a link that names only a
                /// database is naming the thing that engine calls a schema.
                steps.append(.schema(database))
            }
        }

        if let schema, !schema.isEmpty, switchable.contains(.schema) {
            steps.append(.schema(schema))
        }

        return steps
    }
}
