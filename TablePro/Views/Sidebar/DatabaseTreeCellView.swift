//
//  DatabaseTreeCellView.swift
//  TablePro
//

import AppKit
import SwiftUI

/// One row of the object tree. All the hosting geometry is `SidebarHostingCellView`'s and the
/// rename field is `RenamableSidebarCellView`'s; this only knows how to turn a node into the row
/// it draws, and which glyph that row wears while it is being renamed.
final class DatabaseTreeCellView: RenamableSidebarCellView<DatabaseTreeRowView> {
    private var renameSymbolName = "tablecells"

    override var editorSymbolName: String { renameSymbolName }
    override var editorAccessibilityIdentifier: String { "database-tree-rename-field" }

    func configure(
        node: DatabaseTreeNode,
        isFavorite: Bool,
        context: DatabaseTreeRowContext,
        actions: DatabaseTreeRowActions
    ) {
        renameSymbolName = Self.symbolName(for: node)
        update(rootView: DatabaseTreeRowView(
            node: node,
            isFavorite: isFavorite,
            context: context,
            actions: actions
        ))
    }

    private static func symbolName(for node: DatabaseTreeNode) -> String {
        switch node.kind {
        case .table(let ref), .recentTable(let ref):
            return TableRowLogic.iconName(for: ref.table.type)
        case .database(let metadata):
            return metadata.isSystemDatabase ? "gearshape" : "cylinder"
        case .schema:
            return "folder"
        case .routine, .trigger, .status, .recentSection, .objectKindSection,
             .containerObjectKindSection, .hierarchicalSchemaSection, .redisKeysSection, .redisNode:
            return "tablecells"
        }
    }
}
