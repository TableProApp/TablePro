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

    func makeCoordinator() -> DatabaseTreeOutlineCoordinator {
        DatabaseTreeOutlineCoordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = NSOutlineView()
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.rowHeight = 24
        outlineView.indentationPerLevel = 14
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
        outlineView.doubleAction = #selector(DatabaseTreeOutlineCoordinator.handleDoubleClick)

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
