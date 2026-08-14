//
//  DatabaseTreeOutlineView.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

struct DatabaseTreeOutlineView: NSViewRepresentable {
    let connectionId: UUID
    let databaseType: DatabaseType
    let coordinator: MainContentCoordinator?
    let windowState: WindowSidebarState
    let sidebarState: SharedSidebarState
    let viewModel: SidebarViewModel
    let pendingTruncates: Set<String>
    let pendingDeletes: Set<String>
    let searchText: String
    let connectionToken: String
    let activeDatabase: String?
    let activeSchema: String?
    let selectedTables: Set<TableInfo>
    let showRecentTables: Bool

    func makeCoordinator() -> DatabaseTreeOutlineCoordinator {
        DatabaseTreeOutlineCoordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = DatabaseTreeNSOutlineView()
        outlineView.headerView = nil
        outlineView.style = .sourceList
        /// The two metrics come from AppKit rather than from taste: `.small` is the 24pt source
        /// list row, and 13 is the indent a source list steps by. A hand-picked number here is the
        /// difference between a sidebar that lines up with Finder and Xcode and one that nearly does.
        outlineView.rowSizeStyle = .small
        outlineView.indentationPerLevel = 13
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

        context.coordinator.attach(outlineView: outlineView)
        context.coordinator.update(from: self)

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
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
