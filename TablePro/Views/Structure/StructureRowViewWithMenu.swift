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

    /// AppKit takes two routes to a row's menu and this row owns both.
    ///
    /// `KeyHandlingTableView.rightMouseDown` intercepts a click that lands inside the selection and
    /// answers from `contextMenu(for:)`; a click outside it falls through to `super`, which reaches
    /// `menu(for:)`. Overriding only the second is what left the Structure tab showing the data
    /// grid's row commands, Copy as INSERT and Paste and Set Value and Export Results, over a
    /// schema row, and none of Copy Name, Copy Definition or the referenced table, for the
    /// select-then-right-click path that most people take.
    override func menu(for event: NSEvent) -> NSMenu? {
        structureMenu(for: event)
    }

    override func contextMenu(for event: NSEvent) -> NSMenu? {
        structureMenu(for: event)
    }

    private func structureMenu(for event: NSEvent) -> NSMenu? {
        guard structureTab != .ddl, structureTab != .parts, structureTab != .triggers else { return nil }

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

        /// The clicked cell, so the Type or the Default is reachable from the pointer and not only
        /// from `Cmd+C`, which has copied it all along.
        menu.addItem(makeCopyItem(for: event))

        /// No `Cmd+C` on this one. That key copies the clicked cell, which is what the item above
        /// does; advertising it here promised a shortcut that has never copied a column's name.
        let copyNameItem = NSMenuItem(
            title: String(localized: "Copy Name"),
            action: #selector(handleCopyName),
            keyEquivalent: ""
        )
        copyNameItem.target = self
        menu.addItem(copyNameItem)

        let copyDefItem = NSMenuItem(
            title: String(localized: "Copy Definition"),
            action: #selector(handleCopyDefinition),
            keyEquivalent: ""
        )
        copyDefItem.target = self
        menu.addItem(copyDefItem)

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

        addColumnMoveItems(to: menu)

        if isStructureEditable {
            menu.addItem(NSMenuItem.separator())

            /// No key equivalent. This showed `Cmd+D`, which is not the binding `duplicateRow`
            /// carries, and the real one does not reach here either: `MainContentCommandActions`
            /// guards it on `dataGridOwnsSelection` and returns for a schema grid. There is no
            /// keystroke that duplicates a column, so the menu stops claiming one.
            let dupItem = NSMenuItem(
                title: String(localized: "Duplicate"),
                action: #selector(handleDuplicate),
                keyEquivalent: ""
            )
            dupItem.target = self
            menu.addItem(dupItem)

            /// Read from the binding rather than typed in, because this one genuinely works:
            /// `KeyHandlingTableView.keyDown` routes it to the delegate's row delete, and it can
            /// be rebound in Settings, at which point a literal here would start lying.
            let delItem = NSMenuItem(
                title: String(localized: "Delete"),
                action: #selector(handleDelete),
                keyEquivalent: ""
            )
            delItem.target = self
            MenuItemFactory.apply(
                shortcut: .delete, keyboard: AppSettingsManager.shared.keyboard, to: delItem
            )
            menu.addItem(delItem)
        }

        return menu
    }

    /// Built by the delegate rather than here, because this is not the only menu a column row can
    /// raise. `KeyHandlingTableView.rightMouseDown` intercepts a click that lands inside the
    /// selection and answers from `DataGridRowView.contextMenu(for:)` instead, so items added only
    /// in this override are missing from the ordinary select-then-right-click path, which is also
    /// the path the keyboard and assistive technology take.
    private func addColumnMoveItems(to menu: NSMenu) {
        let items = coordinator?.delegate?.dataGridRowStructureMenuItems(forRow: rowIndex) ?? []
        guard !items.isEmpty else { return }
        menu.addItem(NSMenuItem.separator())
        for item in items {
            menu.addItem(item)
        }
    }

    /// The rows a row command acts on, resolved the way the data grid's own menu resolves them.
    ///
    /// A cell range dragged across several rows lives in `selectionController`, and the table view
    /// keeps only its anchor in `selectedRowIndices`, so reading the latter alone shrank Delete
    /// from every row the range covered to one. That was invisible while this menu was reachable
    /// only from a click outside the selection; owning the in-selection route as well is exactly
    /// the case where a range is what the user has.
    private func effectiveIndices() -> Set<Int> {
        coordinator?.currentRowSelection(fallbackRow: rowIndex) ?? [rowIndex]
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

    @objc func runAction() {
        action()
    }
}
