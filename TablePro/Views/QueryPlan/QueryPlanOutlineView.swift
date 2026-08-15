//
//  QueryPlanOutlineView.swift
//  TablePro
//
//  The plan as a real outline: labelled, resizable, sortable columns, keyboard navigation,
//  type-select and VoiceOver all come from NSOutlineView rather than being approximated.
//

import AppKit
import SwiftUI

struct QueryPlanOutlineView: NSViewRepresentable {
    let plan: QueryPlan
    @Binding var selectedNodeId: UUID?

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    func makeCoordinator() -> QueryPlanOutlineCoordinator {
        QueryPlanOutlineCoordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = QueryPlanOutline()
        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.style = .fullWidth
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = 24
        outlineView.indentationPerLevel = 14
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.headerView = NSTableHeaderView()
        outlineView.allowsColumnResizing = true
        outlineView.autosaveName = "com.TablePro.queryPlanOutline"
        outlineView.autosaveTableColumns = true

        // Every EXPLAIN run mints fresh node identities, so persisted expansion would key off
        // items that no longer exist.
        outlineView.autosaveExpandedItems = false
        outlineView.setAccessibilityIdentifier("query-plan-outline")

        context.coordinator.configureColumns(on: outlineView)
        outlineView.outlineTableColumn = outlineView.tableColumns.first
        context.coordinator.outlineView = outlineView
        outlineView.coordinator = context.coordinator
        outlineView.menu = makeMenu(coordinator: context.coordinator)

        context.coordinator.onSelect = { selectedNodeId = $0 }
        context.coordinator.update(plan: plan, differentiateWithoutColor: differentiateWithoutColor)

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.onSelect = { selectedNodeId = $0 }
        context.coordinator.update(plan: plan, differentiateWithoutColor: differentiateWithoutColor)
        context.coordinator.select(nodeId: selectedNodeId)
    }

    private func makeMenu(coordinator: QueryPlanOutlineCoordinator) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = coordinator
        return menu
    }
}

/// Routes the standard Copy command through the responder chain, so Cmd+C and Edit > Copy both
/// reach the selected step instead of needing a hardcoded key handler.
@MainActor
final class QueryPlanOutline: NSOutlineView {
    weak var coordinator: QueryPlanOutlineCoordinator?

    @objc func copy(_ sender: Any?) {
        guard let node = coordinator?.clickedNode else { return }
        ClipboardService.shared.writeText(QueryPlanNodeSummary.text(for: node))
    }
}

extension QueryPlanOutlineCoordinator: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard clickedNode != nil else { return }

        menu.addItem(
            withTitle: String(localized: "Copy Node Details"), action: #selector(copyDetails), keyEquivalent: ""
        )
        menu.addItem(
            withTitle: String(localized: "Copy Operation"), action: #selector(copyOperation), keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: String(localized: "Expand All"), action: #selector(expandAllItems), keyEquivalent: ""
        )
        menu.addItem(
            withTitle: String(localized: "Collapse All"), action: #selector(collapseAllItems), keyEquivalent: ""
        )

        for item in menu.items where item.action != nil {
            item.target = self
        }
    }

    @objc private func copyDetails() {
        guard let node = clickedNode else { return }
        ClipboardService.shared.writeText(QueryPlanNodeSummary.text(for: node))
    }

    @objc private func copyOperation() {
        guard let node = clickedNode else { return }
        ClipboardService.shared.writeText(node.operation)
    }

    @objc private func expandAllItems() {
        expandAll()
    }

    @objc private func collapseAllItems() {
        collapseAll()
    }
}
