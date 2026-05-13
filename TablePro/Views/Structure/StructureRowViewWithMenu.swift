//
//  StructureRowViewWithMenu.swift
//  TablePro
//
//  Custom row view with structure-specific context menu.
//  Provides Copy Name, Copy Definition, Copy As, Duplicate, Delete for structure items.
//

import AppKit

/// Row view providing a context menu tailored to the Structure tab. Inherits
/// selection/emphasis cell invalidation, deleted/inserted-row tint, and the
/// `RowVisualState` source-of-truth from `DataGridRowView`. The context menu
/// reads `visualState.isDeleted` directly, so a single `applyVisualState` call
/// updates both the tint and the menu without a shadow flag to keep in sync.
final class StructureRowViewWithMenu: DataGridRowView {
    var structureTab: StructureTab = .columns
    var isStructureEditable: Bool = true
    var referencedTableName: String?

    var onCopyName: ((Set<Int>) -> Void)?
    var onCopyDefinition: ((Set<Int>) -> Void)?
    var onCopyAsCSV: ((Set<Int>) -> Void)?
    var onCopyAsJSON: ((Set<Int>) -> Void)?
    var onNavigateFK: ((Int) -> Void)?
    var onDuplicate: ((Set<Int>) -> Void)?
    var onDelete: ((Set<Int>) -> Void)?
    var onUndoDelete: ((Int) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard structureTab != .ddl, structureTab != .parts else { return nil }

        let menu = NSMenu()

        if visualState.isDeleted {
            let undoItem = NSMenuItem(
                title: String(localized: "Undo Delete"),
                action: #selector(handleUndoDelete),
                keyEquivalent: ""
            )
            undoItem.target = self
            menu.addItem(undoItem)
            return menu
        }

        let copyNameItem = NSMenuItem(
            title: String(localized: "Copy Name"),
            action: #selector(handleCopyName),
            keyEquivalent: "c"
        )
        copyNameItem.keyEquivalentModifierMask = .command
        copyNameItem.target = self
        menu.addItem(copyNameItem)

        let copyDefItem = NSMenuItem(
            title: String(localized: "Copy Definition"),
            action: #selector(handleCopyDefinition),
            keyEquivalent: ""
        )
        copyDefItem.target = self
        menu.addItem(copyDefItem)

        // Copy As submenu
        let copyAsSubmenu = NSMenu()
        let csvItem = NSMenuItem(
            title: "CSV",
            action: #selector(handleCopyAsCSV),
            keyEquivalent: ""
        )
        csvItem.target = self
        copyAsSubmenu.addItem(csvItem)

        let jsonItem = NSMenuItem(
            title: "JSON",
            action: #selector(handleCopyAsJSON),
            keyEquivalent: ""
        )
        jsonItem.target = self
        copyAsSubmenu.addItem(jsonItem)

        let sqlItem = NSMenuItem(
            title: "SQL",
            action: #selector(handleCopyDefinition),
            keyEquivalent: ""
        )
        sqlItem.target = self
        copyAsSubmenu.addItem(sqlItem)

        let copyAsItem = NSMenuItem(
            title: String(localized: "Copy As"),
            action: nil,
            keyEquivalent: ""
        )
        copyAsItem.submenu = copyAsSubmenu
        menu.addItem(copyAsItem)

        if structureTab == .foreignKeys,
           let tableName = referencedTableName, !tableName.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let navItem = NSMenuItem(
                title: String(format: String(localized: "Open %@"), tableName),
                action: #selector(handleNavigateFK),
                keyEquivalent: ""
            )
            navItem.target = self
            menu.addItem(navItem)
        }

        if isStructureEditable {
            menu.addItem(NSMenuItem.separator())

            let dupItem = NSMenuItem(
                title: String(localized: "Duplicate"),
                action: #selector(handleDuplicate),
                keyEquivalent: "d"
            )
            dupItem.keyEquivalentModifierMask = .command
            dupItem.target = self
            menu.addItem(dupItem)

            let delItem = NSMenuItem(
                title: String(localized: "Delete"),
                action: #selector(handleDelete),
                keyEquivalent: String(
                    UnicodeScalar(NSBackspaceCharacter).map { Character($0) } ?? "\u{8}"
                )
            )
            delItem.keyEquivalentModifierMask = []
            delItem.target = self
            menu.addItem(delItem)
        }

        return menu
    }

    private func effectiveIndices() -> Set<Int> {
        if let selected = coordinator?.selectedRowIndices, !selected.isEmpty {
            return selected
        }
        return [rowIndex]
    }

    @objc private func handleCopyName() { onCopyName?(effectiveIndices()) }
    @objc private func handleCopyDefinition() { onCopyDefinition?(effectiveIndices()) }
    @objc private func handleCopyAsCSV() { onCopyAsCSV?(effectiveIndices()) }
    @objc private func handleCopyAsJSON() { onCopyAsJSON?(effectiveIndices()) }
    @objc private func handleNavigateFK() { onNavigateFK?(rowIndex) }
    @objc private func handleDuplicate() { onDuplicate?(effectiveIndices()) }
    @objc private func handleDelete() { onDelete?(effectiveIndices()) }
    @objc private func handleUndoDelete() { onUndoDelete?(rowIndex) }
}

/// Menu action target for empty-space context menu.
/// Stored as `representedObject` on the menu item to keep it alive while the menu is shown.
final class StructureMenuTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func addNewItem() {
        action()
    }
}
