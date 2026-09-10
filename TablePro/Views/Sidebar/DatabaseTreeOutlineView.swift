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
    let pendingTruncates: Set<DatabaseTreeTableRef>
    let pendingDeletes: Set<DatabaseTreeTableRef>
    let searchText: String
    /// Rebuilds the tree when the session comes back, which is the one thing outside the metadata
    /// services that invalidates every node at once.
    let isConnected: Bool
    let activeDatabase: String?
    let activeSchema: String?
    let selectedTables: Set<DatabaseTreeTableRef>
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
        let scrollView = SidebarOutlineScaffold.makeScrollView(
            outlineView: outlineView,
            configuration: SidebarOutlineScaffold.Configuration(
                columnIdentifier: "DatabaseTreeColumn",
                allowsMultipleSelection: true,
                rowSizePreference: rowSizePreference
            )
        )

        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.target = context.coordinator
        /// No `action`: it arrives on mouse up, a whole gesture after the selection the user can
        /// already see. Opening follows the selection instead, so `doubleAction` is free to mean
        /// "keep this one" on a table row and to disclose on a container.
        outlineView.doubleAction = #selector(DatabaseTreeOutlineCoordinator.handleDoubleClick)
        outlineView.selectionClearing = context.coordinator
        outlineView.primaryActionTarget = context.coordinator

        /// The menu hangs off the table, not off the row's hosted view, so `NSTableView`'s own
        /// secondary-click handling runs: it sets `clickedRow`, draws the clicked-row highlight, and
        /// answers a right-click in the empty area below the last row.
        let menu = NSMenu()
        menu.delegate = context.coordinator
        outlineView.menu = menu

        context.coordinator.attach(outlineView: outlineView)
        context.coordinator.update(from: self)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        SidebarOutlineScaffold.applyRowSize(rowSizePreference, to: nsView)
        context.coordinator.update(from: self)
    }
}

/// Escape clears the selection, the first step of the two-step Escape every TablePro list uses.
/// `NSTableView` implements `cancelOperation(_:)` to interrupt type-select and leaves the selection
/// alone, so without this the Table menu stays scoped to a row the user tried to deselect.
final class DatabaseTreeNSOutlineView: SidebarOutlineView {
    weak var selectionClearing: (any DatabaseTreeSelectionClearing)?
    weak var primaryActionTarget: DatabaseTreeOutlineCoordinator?

    override func cancelOperation(_ sender: Any?) {
        super.cancelOperation(sender)
        selectionClearing?.clearSelection()
    }

    override func insertNewline(_ sender: Any?) {
        primaryActionTarget?.performPrimaryAction()
    }
}

@MainActor
protocol DatabaseTreeSelectionClearing: AnyObject {
    func clearSelection()
}
