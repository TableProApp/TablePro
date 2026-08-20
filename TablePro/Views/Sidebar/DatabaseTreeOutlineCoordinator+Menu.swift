//
//  DatabaseTreeOutlineCoordinator+Menu.swift
//  TablePro
//

import AppKit
import TableProPluginKit

/// The object tree's contextual menu, owned by the outline view.
///
/// `NSTableView`'s own secondary-click handling is what sets `clickedRow` and draws the clicked-row
/// highlight, so the menu has to hang off the table and be filled in `menuNeedsUpdate`. Overriding
/// `menu(for:)` would lose both, and a SwiftUI `.contextMenu` on the hosted row, which is what this
/// replaced, never let the table see the click at all.
extension DatabaseTreeOutlineCoordinator: NSMenuDelegate {
    internal func menuNeedsUpdate(_ menu: NSMenu) {
        SidebarMenuBuilder.fill(
            menu,
            with: DatabaseTreeMenuSpec.items(for: menuContext()),
            target: self,
            action: #selector(performMenuCommand(_:))
        )
    }

    /// `clickedRow` is a display position, so the node is resolved through the outline view rather
    /// than by indexing anything. A right-click below the last row reports -1, which is the empty
    /// area and gets its own menu.
    private func clickedNode() -> DatabaseTreeNode? {
        guard let outlineView, outlineView.clickedRow >= 0 else { return nil }
        return outlineView.item(atRow: outlineView.clickedRow) as? DatabaseTreeNode
    }

    private func menuContext() -> DatabaseTreeMenuContext {
        let clicked = clickedNode()
        let clickedRef = clicked.flatMap(DatabaseTreeSelection.tableRef)
        let settings = AppSettingsManager.shared.general
        return DatabaseTreeMenuContext(
            clicked: clicked?.kind,
            selectedTables: Set(selectedRefs().map(\.table)),
            selectedContainers: selectedContainerRefs(),
            activeDatabase: activeDatabase,
            activeSchema: activeSchema,
            canReachOtherDatabases: databaseType.supportsConnectionPooling,
            systemSchemas: systemSchemas,
            isReadOnly: mainCoordinator?.safeModeLevel.blocksAllWrites ?? false,
            supportsImport: PluginManager.shared.supportsImport(for: databaseType),
            importFormats: PluginManager.shared.importFormatOptions(for: databaseType),
            maintenanceOperations: mainCoordinator?.supportedMaintenanceOperations() ?? [],
            dropEligibility: ContainerDropEligibility.Context(
                activeDatabase: activeDatabase,
                activeSchema: activeSchema,
                supportsDropDatabase: PluginManager.shared.supportsDropDatabase(for: databaseType),
                supportsDropSchema: PluginManager.shared.supportsDropSchema(for: databaseType),
                isReadOnly: mainCoordinator?.safeModeLevel.blocksAllWrites ?? false
            ),
            containerEntityName: PluginManager.shared.containerEntityName(for: databaseType),
            containerEntityNamePlural: PluginManager.shared.containerEntityNamePlural(for: databaseType),
            schemaEntityName: PluginManager.shared.schemaEntityName(for: databaseType),
            schemaEntityNamePlural: PluginManager.shared.schemaEntityNamePlural(for: databaseType),
            objectKindTitles: objectKindTitles(),
            isFavorite: clickedRef.map { isFavorite($0) } ?? false,
            showObjectIcons: settings.showObjectIcons,
            showObjectComments: settings.showObjectComments,
            rowSize: settings.sidebarRowSize,
            canFilterDatabases: PluginManager.shared.supportsDatabaseTree(for: databaseType)
                && sidebarState?.sidebarLayout == .tree,
            hasDatabaseFilter: !(sidebarState?.databaseFilterSelected.isEmpty ?? true)
        )
    }

    private func objectKindTitles() -> [SidebarObjectKind: String] {
        let tableEntityName = PluginManager.shared.tableEntityName(for: databaseType)
        var titles: [SidebarObjectKind: String] = [:]
        for kind in SidebarObjectKind.allCases {
            titles[kind] = kind.title(tableEntityName: tableEntityName)
        }
        return titles
    }

    @objc
    internal func performMenuCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? SidebarMenuCommandBox<SidebarMenuCommand> else { return }
        perform(box.command)
    }
}
