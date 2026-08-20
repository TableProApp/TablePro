//
//  QueryPlanOutlineCoordinator.swift
//  TablePro
//
//  Data source, delegate and menu for the plan outline.
//

import AppKit
import SwiftUI

@MainActor
final class QueryPlanOutlineCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onSelect: (UUID?) -> Void = { _ in }

    weak var outlineView: NSOutlineView?

    private(set) var root: QueryPlanOutlineNode?
    private var planId: UUID?
    private var differentiateWithoutColor = false

    // MARK: - Content

    func update(plan: QueryPlan, differentiateWithoutColor: Bool) {
        let colorChanged = self.differentiateWithoutColor != differentiateWithoutColor
        self.differentiateWithoutColor = differentiateWithoutColor

        guard planId != plan.rootNode.id else {
            if colorChanged { outlineView?.reloadData() }
            return
        }

        planId = plan.rootNode.id
        root = QueryPlanOutlineNode(plan.rootNode)

        // The rebuilt tree is in parse order, so a sort indicator left over from the previous
        // plan would advertise an order the rows are not in.
        outlineView?.sortDescriptors = []
        outlineView?.reloadData()
        expandAll()
        selectRootRow()
    }

    /// Only ever drives the selection forward. A nil never clears the row, because the parent's
    /// binding starts nil and would otherwise wipe the root selection made on first load.
    func select(nodeId: UUID?) {
        guard let outlineView, let nodeId, let node = find(nodeId, in: root) else { return }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        guard outlineView.selectedRow != row else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    func expandAll() {
        guard let outlineView, let root else { return }
        outlineView.expandItem(root, expandChildren: true)
    }

    func collapseAll() {
        guard let outlineView, let root else { return }
        outlineView.collapseItem(root, collapseChildren: true)
    }

    // MARK: - Columns

    func configureColumns(on outlineView: NSOutlineView) {
        guard outlineView.tableColumns.isEmpty else { return }

        for column in QueryPlanOutlineColumn.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = column.minimumWidth
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                key: column.rawValue,
                ascending: QueryPlanOutlineSort.defaultAscending(for: column)
            )
            outlineView.addTableColumn(tableColumn)
        }
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? QueryPlanOutlineNode)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = outlineView.sortDescriptors.first,
              let key = descriptor.key,
              let column = QueryPlanOutlineColumn(rawValue: key),
              let root
        else { return }

        let selected = selectedNodeId
        self.root = root.sorted(
            by: QueryPlanOutlineSort.comparator(key: column, ascending: descriptor.ascending)
        )
        outlineView.reloadData()
        expandAll()
        select(nodeId: selected)
    }

    private func children(of item: Any?) -> [QueryPlanOutlineNode] {
        guard let node = item as? QueryPlanOutlineNode else {
            return root.map { [$0] } ?? []
        }
        return node.children
    }

    // MARK: - Delegate

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? QueryPlanOutlineNode,
              let identifier = tableColumn?.identifier,
              let column = QueryPlanOutlineColumn(rawValue: identifier.rawValue)
        else { return nil }

        let content: AnyView
        switch column {
        case .operation:
            content = AnyView(
                QueryPlanOperationCellView(
                    node: node.source,
                    differentiateWithoutColor: differentiateWithoutColor
                )
            )
        case .cost:
            content = AnyView(
                QueryPlanMetricCellView(
                    text: node.source.costRangeText(fractionDigits: 2),
                    label: QueryPlanLabels.cost
                )
            )
        case .rows:
            content = AnyView(
                QueryPlanMetricCellView(
                    text: node.source.estimatedRows.map { $0.formatted(.number.grouping(.automatic)) },
                    label: QueryPlanLabels.rows
                )
            )
        case .actualTime:
            content = AnyView(
                QueryPlanMetricCellView(
                    text: node.source.actualTotalTime.map(QueryPlanLabels.milliseconds),
                    label: QueryPlanLabels.actualTime
                )
            )
        }

        return hostingCell(identifier: identifier, outlineView: outlineView, content: content)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        onSelect(selectedNodeId)
    }

    var selectedNodeId: UUID? {
        guard let outlineView, outlineView.selectedRow >= 0 else { return nil }
        return (outlineView.item(atRow: outlineView.selectedRow) as? QueryPlanOutlineNode)?.source.id
    }

    var clickedNode: QueryPlanNode? {
        guard let outlineView else { return nil }
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0 else { return nil }
        return (outlineView.item(atRow: row) as? QueryPlanOutlineNode)?.source
    }

    // MARK: - Private

    /// Publishing the root selection is deferred, because the first update runs while SwiftUI is
    /// building the view and a binding written there is dropped.
    private func selectRootRow() {
        guard let outlineView, outlineView.numberOfRows > 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let rootId = selectedNodeId
        Task { @MainActor [weak self] in
            self?.onSelect(rootId)
        }
    }

    private func find(_ id: UUID, in node: QueryPlanOutlineNode?) -> QueryPlanOutlineNode? {
        guard let node else { return nil }
        if node.source.id == id { return node }
        for child in node.children {
            if let found = find(id, in: child) { return found }
        }
        return nil
    }

    private func hostingCell(
        identifier: NSUserInterfaceItemIdentifier,
        outlineView: NSOutlineView,
        content: AnyView
    ) -> NSView {
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSHostingView<AnyView> {
            reused.rootView = content
            return reused
        }
        let hosting = NSHostingView(rootView: content)
        hosting.identifier = identifier
        return hosting
    }
}
