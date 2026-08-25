//
//  WorkspaceAnchoring.swift
//  TablePro
//

import Foundation

/// Which containers a connection's open tabs hold open.
///
/// This answers for tabs alone. What the connections strip lists is what the connection has open:
/// `ConnectionWorkspace.openedContainers`, which the user adds to by browsing to a container and
/// empties by closing its entry, plus whatever tabs hold. Anchoring used to be the whole of that
/// membership, under the rule "the rail lists work, not history", and deriving a switcher's rows
/// from what its rows were being used for is what let clicking one entry delete another.
///
/// A tab holds its container when it carries work that would be lost if the row went away. A brand
/// new query tab with nothing in it is not work, so a window restoring an empty scratch tab into a
/// container nobody has opened does not open a row for it. Everything else, including a query tab
/// the user has typed into, holds its container until its last tab closes.
internal enum WorkspaceAnchoring {
    /// A tab's identity as far as anchoring is concerned. Comparing these across a tab
    /// mutation is what tells the rail whether it has to reload.
    internal struct Anchor: Hashable {
        internal let databaseName: String
        internal let schemaName: String?
        internal let holdsContainer: Bool
    }

    /// Whether a tab carries work that would be lost. A brand new query tab does not; everything
    /// else does, including a query tab the user has typed into.
    internal static func hasWork(_ tab: QueryTab) -> Bool {
        guard tab.tabType == .query else { return true }
        return tab.hasUserInteraction
            || !tab.content.query.isEmpty
            || tab.content.sourceFileURL != nil
    }

    /// A tab holds a container only if it has work AND can name the container it belongs to.
    /// The two have to be decided together: only `.table` tabs are given a schema, so on a
    /// schema-switching engine a query tab full of unsaved SQL would otherwise be reported as
    /// holding a container it cannot name, and its row would vanish from the rail on the next
    /// switch. That is exactly the loss the anchoring rule exists to prevent.
    internal static func holdsContainer(_ tab: QueryTab, target: ContainerSwitchTarget?) -> Bool {
        guard containerName(of: tab, target: target) != nil else { return false }
        return hasWork(tab)
    }

    /// What a tab's container is called, whether or not the tab holds it open. Close commands
    /// name every tab they are about to close; the rail only lists the ones worth a row.
    internal static func containerName(of tab: QueryTab, target: ContainerSwitchTarget?) -> String? {
        named(database: tab.tableContext.databaseName, schema: tab.tableContext.schemaName, target: target)
    }

    internal static func container(of tab: QueryTab, target: ContainerSwitchTarget?) -> String? {
        guard holdsContainer(tab, target: target) else { return nil }
        return containerName(of: tab, target: target)
    }

    internal static func containers(in tabs: [QueryTab], target: ContainerSwitchTarget?) -> Set<String> {
        Set(tabs.compactMap { container(of: $0, target: target) })
    }

    /// Change detection only, so it stays free of the engine's container target: any change to a
    /// tab's database, schema or work state can move a rail row, whichever of them this engine
    /// keys on.
    internal static func anchors(in tabs: [QueryTab]) -> [Anchor] {
        tabs.map {
            Anchor(
                databaseName: $0.tableContext.databaseName,
                schemaName: $0.tableContext.schemaName,
                holdsContainer: hasWork($0)
            )
        }
    }

    /// The container the connection is browsing right now. It always earns a row, even
    /// with no tabs holding it, because it is where the next tab will open.
    internal static func browsedContainer(of session: ConnectionSession, target: ContainerSwitchTarget?) -> String? {
        named(database: session.resolvedBrowseDatabase, schema: session.browseSchema, target: target)
    }

    /// The container a connection names before it has a session to browse with. A schema
    /// switching engine names none, because a saved connection records no schema.
    internal static func defaultContainer(
        of connection: DatabaseConnection,
        target: ContainerSwitchTarget?
    ) -> String? {
        named(database: connection.database, schema: nil, target: target)
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
