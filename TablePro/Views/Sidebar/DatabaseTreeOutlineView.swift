//
//  DatabaseTreeOutlineView.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

struct DatabaseTreeOutlineView: NSViewRepresentable {
    /// The system's own sidebar row size, from System Settings > Appearance. Reading it here is
    /// what makes a change to that setting reach the outline: SwiftUI re-runs `updateNSView` when
    /// the environment value changes, so nothing has to be observed by hand.
    @Environment(\.sidebarRowSize) private var systemRowSize

    let connectionId: UUID
    let databaseType: DatabaseType
    let coordinator: MainContentCoordinator?
    let windowState: WindowSidebarState
    let sidebarState: SharedSidebarState
    let viewModel: SidebarViewModel
    let pendingTruncates: Set<String>
    let pendingDeletes: Set<String>
    let searchText: String
    /// Rebuilds the tree when the session comes back, which is the one thing outside the metadata
    /// services that invalidates every node at once.
    let isConnected: Bool
    let activeDatabase: String?
    let activeSchema: String?
    let selectedTables: Set<TableInfo>
    let showRecentTables: Bool
    let rowSizePreference: SidebarRowSizePreference

    /// The size the rows are actually drawn at, which is the system's unless the user overrode it.
    var resolvedRowSize: SidebarRowSize {
        SidebarRowSizeResolver.resolve(preference: rowSizePreference, system: systemRowSize)
    }

    func makeCoordinator() -> DatabaseTreeOutlineCoordinator {
        DatabaseTreeOutlineCoordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = DatabaseTreeNSOutlineView()
        outlineView.headerView = nil
        outlineView.style = .sourceList
        /// `.sourceList` already supplies the row height and the indent per level, and `.default`
        /// is how a table says "the size the user picked in Appearance". Pinning `.small` here made
        /// the sidebar one size step shorter than Finder on a stock Mac, and deaf to that setting
        /// while the workspace rail beside it still followed it.
        outlineView.rowSizeStyle = SidebarRowSizeResolver.rowSizeStyle(for: rowSizePreference)
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.floatsGroupRows = false
        outlineView.autosaveExpandedItems = false
        outlineView.backgroundColor = .clear

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("DatabaseTreeColumn"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.target = context.coordinator
        /// No `action`: it arrives on mouse up, a whole gesture after the selection the user can
        /// already see. Opening follows the selection instead. `doubleAction` only discloses.
        outlineView.doubleAction = #selector(DatabaseTreeOutlineCoordinator.handleDoubleClick)
        outlineView.selectionClearing = context.coordinator

        /// The menu hangs off the table, not off the row's hosted view, so `NSTableView`'s own
        /// secondary-click handling runs: it sets `clickedRow`, draws the clicked-row highlight, and
        /// answers a right-click in the empty area below the last row.
        let menu = NSMenu()
        menu.delegate = context.coordinator
        outlineView.menu = menu

        context.coordinator.attach(outlineView: outlineView)
        context.coordinator.update(from: self)

        /// No `scrollerStyle`: it is the user's "Show scroll bars" setting in General settings, and
        /// `NSScrollView` already follows it.
        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let outlineView = nsView.documentView as? NSOutlineView {
            let style = SidebarRowSizeResolver.rowSizeStyle(for: rowSizePreference)
            if outlineView.rowSizeStyle != style { outlineView.rowSizeStyle = style }
        }
        context.coordinator.update(from: self)
    }
}

/// Escape clears the selection, the first step of the two-step Escape every TablePro list uses.
/// `NSTableView` implements `cancelOperation(_:)` to interrupt type-select and leaves the selection
/// alone, so without this the Table menu stays scoped to a row the user tried to deselect.
final class DatabaseTreeNSOutlineView: SidebarOutlineView {
    weak var selectionClearing: (any DatabaseTreeSelectionClearing)?

    override func cancelOperation(_ sender: Any?) {
        super.cancelOperation(sender)
        selectionClearing?.clearSelection()
    }
}

@MainActor
protocol DatabaseTreeSelectionClearing: AnyObject {
    func clearSelection()
}
