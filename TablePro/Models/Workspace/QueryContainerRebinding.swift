//
//  QueryContainerRebinding.swift
//  TablePro
//

import Foundation

/// Points a query tab at another entry from the editor's container picker.
internal enum QueryContainerRebinding {
    /// On an engine whose entries are databases the schema goes with the old database: a schema
    /// only means something inside the database that holds it, and a moved tab kept naming one the
    /// new database may not have. On one whose entries are schemas the database stays.
    internal static func rebind(
        _ context: inout TabTableContext,
        to container: String,
        target: ContainerSwitchTarget?
    ) {
        switch target {
        case .database:
            context.databaseName = container
            context.schemaName = nil
        case .schema:
            context.schemaName = container
        case nil:
            break
        }
    }
}
