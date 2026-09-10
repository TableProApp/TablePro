//
//  DatabaseTreeMenuContext.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Everything the object tree's contextual menu depends on, as values.
///
/// `clicked` is nil for a right-click in the empty area below the last row, which `NSOutlineView`
/// reports as `clickedRow == -1`. That case used to produce no menu at all.
internal struct DatabaseTreeMenuContext {
    internal let clicked: DatabaseTreeNode.Kind?
    internal let selectedTables: Set<DatabaseTreeTableRef>
    internal let selectedContainers: [DatabaseContainerRef]
    internal let activeDatabase: String?
    internal let activeSchema: String?
    /// Whether this engine can open a second connection to another database on the server, which
    /// is what lets the export dialog scope itself to a database other than the active one.
    internal let canReachOtherDatabases: Bool
    internal let systemSchemas: Set<String>
    internal let isReadOnly: Bool
    internal let supportsImport: Bool
    internal let importFormats: [ImportFormatOption]
    internal let maintenanceOperations: [String]
    internal let dropEligibility: ContainerDropEligibility.Context
    internal let renameEligibility: ObjectRenameEligibility.Context
    internal let containerEntityName: String
    internal let containerEntityNamePlural: String
    internal let schemaEntityName: String
    internal let schemaEntityNamePlural: String
    internal let objectKindTitles: [SidebarObjectKind: String]
    internal let isFavorite: Bool
    /// Keyed per database rather than resolved for the clicked row alone, because a right-click
    /// inside a multi-selection acts on the whole selection and those databases need not share a tag.
    internal var favoriteDatabaseEnvironments: [String: FavoriteDatabaseEnvironment] = [:]
    internal let showObjectIcons: Bool
    internal let showObjectComments: Bool
    internal let rowSize: SidebarRowSizePreference
    internal var canFilterDatabases: Bool = false
    internal var hasDatabaseFilter: Bool = false
    /// Copying reads the source and writes somewhere else, so it needs a driver that reports
    /// structure and a target that is not this connection's read-only self.
    internal var canCopyObjects: Bool = false
    /// Duplicating means creating a database, which is the same test the New Database command uses.
    internal var canDuplicateDatabase: Bool = false

    /// Whether this connection has a dump tool at all. Backing up writes nothing to the database,
    /// so safe mode does not gate it, which is the same rule File > Backup Dump follows.
    internal var canBackUp: Bool = false
    /// Whether the driver can offer a CREATE TYPE template. Read-only mode still hides the item.
    internal var canCreateType: Bool = false
}
