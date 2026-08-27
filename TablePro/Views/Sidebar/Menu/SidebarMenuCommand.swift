//
//  SidebarMenuCommand.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// What a sidebar menu item does, with its targets already resolved.
///
/// A command carries values rather than a closure so the spec that produces it stays a pure
/// function of its inputs and can be asserted in a unit test. Resolving the targets here also means
/// the clicked-versus-selection rule runs once, while the menu is being built, rather than again
/// when the item fires against a selection the user may have changed in between.
internal enum SidebarMenuCommand: Equatable {
    case createTable
    case createView
    case filterDatabases
    case showAllDatabases
    case openInNewTab(DatabaseTreeTableRef)
    case editViewDefinition(DatabaseTreeTableRef)
    case showStructure(DatabaseTreeTableRef)
    case showERDiagram
    case copyTableNames([String])
    /// Every command that reaches the database carries the row it was raised from, because the
    /// session may be browsing a different database than the one the user right-clicked in. Acting
    /// without switching there first runs the command against a same-named table somewhere else,
    /// which for Truncate and Drop destroys the wrong data.
    case exportTables(names: Set<String>, ref: DatabaseTreeTableRef)
    case importTables(formatId: String, ref: DatabaseTreeTableRef)
    case maintenance(operation: String, tableName: String, ref: DatabaseTreeTableRef)
    /// Queued rather than run, so these carry every target in full: a queue keyed by name is
    /// resolved against whatever the tab in front points at by the time Save runs.
    case truncateTables(targets: [DatabaseTreeTableRef], ref: DatabaseTreeTableRef)
    case dropTables(targets: [DatabaseTreeTableRef], ref: DatabaseTreeTableRef)
    case toggleFavorite(DatabaseTreeTableRef)
    case removeRecent(DatabaseTreeTableRef)
    case clearRecents
    case useAsActive(DatabaseContainerRef)
    case setFavoriteDatabases(databases: [String], environment: FavoriteDatabaseEnvironment)
    case removeFavoriteDatabases([String])
    case refreshContainers([DatabaseContainerRef])
    case copyContainerNames([DatabaseContainerRef])
    case exportContainers([DatabaseContainerRef])
    case dropContainers([DatabaseContainerRef])
    case showAllTablesMetadata
    case refreshObjectKind(SidebarObjectKind)
    case refreshContainerObjectKind(DatabaseTreeObjectGroup)
    case refreshHierarchicalSchema(String)
    case copyText(String)
    case showObjectSource(DatabaseObjectRef)
    case copyRedisNamespacePrefix(String)
    case copyRedisKey(String)
    case openRedisKey(key: String, keyType: String)
    case toggleObjectIcons
    case toggleObjectComments
    case setRowSize(SidebarRowSizePreference)
}
