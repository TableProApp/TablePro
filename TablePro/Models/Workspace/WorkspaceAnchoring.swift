//
//  WorkspaceAnchoring.swift
//  TablePro
//

import Foundation

/// Which container a tab belongs to, and so which connections-strip entry lists it.
///
/// Each entry owns its tabs: the tab strip shows the selected entry's tabs, and every container a
/// tab names is an entry, so no tab ever sits behind an entry the strip does not list. What else the
/// strip lists is `ConnectionWorkspace.openedContainers`, which the user adds to by browsing to a
/// container and empties by closing its entry.
///
/// A tab that names no container belongs to no entry and is shown in all of them: a server
/// dashboard, or a query tab on an engine whose query tabs run against whatever is being browsed.
internal enum WorkspaceAnchoring {
    /// A tab's identity as far as anchoring is concerned. Comparing these across a tab
    /// mutation is what tells the rail whether it has to reload.
    internal struct Anchor: Hashable {
        internal let databaseName: String
        internal let schemaName: String?
    }

    /// What a tab's container is called, or nil when the tab belongs to every entry.
    internal static func containerName(of tab: QueryTab, target: ContainerSwitchTarget?) -> String? {
        named(database: tab.tableContext.databaseName, schema: tab.tableContext.schemaName, target: target)
    }

    internal static func containers(in tabs: [QueryTab], target: ContainerSwitchTarget?) -> Set<String> {
        Set(tabs.compactMap { containerName(of: $0, target: target) })
    }

    /// Change detection only, so it stays free of the engine's container target: any change to a
    /// tab's database or schema can move a rail row, whichever of them this engine keys on.
    internal static func anchors(in tabs: [QueryTab]) -> [Anchor] {
        tabs.map {
            Anchor(databaseName: $0.tableContext.databaseName, schemaName: $0.tableContext.schemaName)
        }
    }

    /// The container the connection is browsing right now. It always earns a row, even
    /// with no tabs holding it, because it is where the next tab will open.
    internal static func browsedContainer(of session: ConnectionSession, target: ContainerSwitchTarget?) -> String? {
        named(database: session.resolvedBrowseDatabase, schema: session.browseSchema, target: target)
    }

    /// The entry a saved database and schema pair names, such as the one a connection was last on.
    internal static func containerName(
        database: String?,
        schema: String?,
        target: ContainerSwitchTarget?
    ) -> String? {
        named(database: database ?? "", schema: schema, target: target)
    }

    /// The container a connection names before it has a session to browse with. A schema
    /// switching engine names none, because a saved connection records no schema.
    internal static func defaultContainer(
        of connection: DatabaseConnection,
        target: ContainerSwitchTarget?
    ) -> String? {
        named(database: connection.database, schema: nil, target: target)
    }

    /// The entry a dropped or renamed database or schema is listed under, or nil when that kind of
    /// container is not what this engine's entries are: a schema dropped inside a PostgreSQL
    /// database is not an entry of its own.
    internal static func entryName(of container: DatabaseContainerRef, target: ContainerSwitchTarget?) -> String? {
        switch (target, container.kind) {
        case (.database, .database):
            return container.database.flatMap { $0.isEmpty ? nil : $0 }
        case (.schema, .schema):
            return container.schema.flatMap { $0.isEmpty ? nil : $0 }
        default:
            return nil
        }
    }

    /// An engine that switches neither database nor schema has one container, and naming it
    /// after a tab's database would split it into rows the rail has no way to activate.
    private static func named(database: String, schema: String?, target: ContainerSwitchTarget?) -> String? {
        let name: String
        switch target {
        case .schema:
            name = schema ?? ""
        case .database:
            name = database
        case nil:
            return nil
        }
        return name.isEmpty ? nil : name
    }
}
