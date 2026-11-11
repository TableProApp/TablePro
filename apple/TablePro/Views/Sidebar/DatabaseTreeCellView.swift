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
    private var renameGlyph = RenameGlyph.symbol("tablecells")

    /// Resolved when asked rather than when configured, so a rename begun after the icon style
    /// changed wears the new glyph, as the hosted row already does.
    var renameIcon: ObjectIcon {
        switch renameGlyph {
        case .object(let kind):
            return ObjectIconProvider.icon(for: kind, style: AppSettingsManager.shared.appearance.objectIconStyle)
        case .symbol(let name):
            return ObjectIcon(symbolName: name)
        }
    }

    override var editorSymbolName: String { renameIcon.symbolName }
    override var editorSymbolTint: NSColor? { renameIcon.tint?.nsColor }
    override var editorAccessibilityIdentifier: String { "database-tree-rename-field" }

    func configure(
        node: DatabaseTreeNode,
        isFavorite: Bool,
        context: DatabaseTreeRowContext,
        actions: DatabaseTreeRowActions
    ) {
        renameGlyph = Self.renameGlyph(for: node)
        update(rootView: DatabaseTreeRowView(
            node: node,
            isFavorite: isFavorite,
            context: context,
            actions: actions
        ))
    }

    private enum RenameGlyph {
        case object(ObjectIconKind)
        case symbol(String)
    }

    private static func renameGlyph(for node: DatabaseTreeNode) -> RenameGlyph {
        switch node.kind {
        case .table(let ref), .recentTable(let ref), .favoriteTable(let ref), .temporaryTable(let ref):
            return .object(.relation(ref.table.type))
        case .partition:
            return .object(.partition)
        case .database(let metadata):
            return .object(metadata.isSystemDatabase ? .systemDatabase : .database)
        case .schema:
            return .object(.schema)
        case .tableFolder:
            return .object(.tableFolder)
        case .connectionGroup:
            return .symbol("folder")
        case .savedConnection:
            return .symbol("server.rack")
        case .routine, .trigger, .userType, .status, .recentSection, .favoritesSection, .temporarySection,
             .foldersSection,
             .objectKindSection, .containerObjectKindSection, .hierarchicalSchemaSection, .redisKeysSection, .redisNode,
             .tableDetailGroup, .tableDetail:
            return .symbol("tablecells")
        }
    }
}
