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
    case createView
    case openInNewTab(DatabaseTreeTableRef)
    case editViewDefinition(DatabaseTreeTableRef)
    case showStructure(DatabaseTreeTableRef)
    case showERDiagram
    case copyTableNames([String])
    case exportTables(Set<String>)
    case importTables(formatId: String)
    case maintenance(operation: String, tableName: String)
    case truncateTables([String])
    case dropTables([String])
    case toggleFavorite(DatabaseTreeTableRef)
    case removeRecent(DatabaseTreeTableRef)
    case clearRecents
    case useAsActive(DatabaseContainerRef)
    case refreshContainers([DatabaseContainerRef])
    case copyContainerNames([DatabaseContainerRef])
    case exportContainers([DatabaseContainerRef])
    case dropContainers([DatabaseContainerRef])
    case showAllTablesMetadata
    case refreshObjectKind(SidebarObjectKind)
    case refreshHierarchicalSchema(String)
    case copyText(String)
    case showRoutineDDL(DatabaseTreeRoutineRef)
    case copyRedisNamespacePrefix(String)
    case copyRedisKey(String)
    case openRedisKey(key: String, keyType: String)
    case toggleObjectIcons
    case toggleObjectComments
    case setRowSize(SidebarRowSizePreference)
}
