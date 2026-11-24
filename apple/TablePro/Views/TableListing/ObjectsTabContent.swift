//
//  ObjectsTabContent.swift
//  TablePro
//

import SwiftUI

/// The Objects tab with the kinds its picker offers. The picker counts the sidebar's own lists, so this view observes
/// them itself: a list that loads or changes redraws this tab, and the editor area around it keeps observing nothing
/// of the catalog.
struct ObjectsTabContent: View {
    @ObservedObject private var treeService = DatabaseTreeMetadataService.shared
    let model: TableListingViewModel
    let databaseType: DatabaseType
    let scope: DatabaseScope
    let declared: Set<SidebarObjectKind>
    let kind: SidebarObjectKind
    let kindTitle: (SidebarObjectKind) -> String
    let onSelectKind: (SidebarObjectKind) -> Void

    var body: some View {
        TableListingTabView(
            model: model,
            databaseType: databaseType,
            kinds: ObjectListingKinds.available(itemCounts: itemCounts, declared: declared, current: kind),
            kindTitle: kindTitle,
            onSelectKind: onSelectKind
        )
    }

    private var itemCounts: [SidebarObjectKind: Int] {
        ObjectListingKinds.itemCounts(
            tables: treeService.tables(connectionId: scope.connectionId, database: scope.database, schema: scope.schema),
            routines: treeService.routines(connectionId: scope.connectionId, database: scope.database, schema: scope.schema),
            triggers: treeService.triggers(connectionId: scope.connectionId, database: scope.database, schema: scope.schema),
            types: treeService.userDefinedTypes(connectionId: scope.connectionId, database: scope.database, schema: scope.schema)
        )
    }
}
