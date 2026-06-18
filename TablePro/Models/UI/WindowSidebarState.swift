//
//  WindowSidebarState.swift
//  TablePro
//

import Foundation
import Observation
import TableProPluginKit

struct DatabaseSchemaKey: Hashable, Sendable {
    let database: String
    let schema: String
}

@MainActor
@Observable
internal final class WindowSidebarState {
    var selectedTables: Set<TableInfo> = []
    var expandedTreeSchemas: Set<String> = []
    var expandedTreeDatabases: Set<String> = []
    var expandedTreeDatabaseSchemas: Set<DatabaseSchemaKey> = []
}
