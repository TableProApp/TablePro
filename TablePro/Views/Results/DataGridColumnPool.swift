//
//  DataGridColumnPool.swift
//  TablePro
//

import AppKit

@MainActor
final class DataGridColumnPool {
    private var pooledColumns: [NSTableColumn] = []
    private weak var attachedTableView: NSTableView?

    /// Columns the user hid, kept apart from the ones the window unmounts so a window slide can
    /// never bring a hidden column back.
    private var userHiddenIdentifiers: Set<NSUserInterfaceItemIdentifier> = []
    /// Slots the current result actually uses. The pool only grows, so the surplus slots past the
    /// result's column count stay attached and hidden, and windowing must never mount one.
    private var activeIdentifiers: Set<NSUserInterfaceItemIdentifier> = []

    var totalSlots: Int { pooledColumns.count }

    func attach(to tableView: NSTableView) {
        attachedTableView = tableView
    }

    /// Whether the result presents this column at all, which is a different question from whether
    /// the window currently has it mounted.
    ///
    /// `isHidden` answers both at once, and everything that asks "which columns is the user
    /// looking at" (copy, find, cell navigation, size-all) means this one. Reading `isHidden`
    /// there silently narrows those to the columns near the viewport.
    func presentsColumn(_ column: NSTableColumn) -> Bool {
        activeIdentifiers.contains(column.identifier) && !userHiddenIdentifiers.contains(column.identifier)
    }

    var hasUserHiddenColumns: Bool { !userHiddenIdentifiers.isEmpty }

    /// Whether this position in `tableColumns` holds one of the columns the result presents.
    ///
    /// The row-number column is an attached column too, and the pool keeps the surplus slots of a
    /// previously wider result attached and hidden, so no fixed position answers this.
    func presentsColumn(atTableColumnIndex index: Int, in tableView: NSTableView) -> Bool {
        guard index >= 0, index < tableView.tableColumns.count else { return false }
        return presentsColumn(tableView.tableColumns[index])
    }

    func firstPresentedColumnIndex(in tableView: NSTableView) -> Int? {
        tableView.tableColumns.firstIndex { presentsColumn($0) }
    }

    func lastPresentedColumnIndex(in tableView: NSTableView) -> Int? {
        tableView.tableColumns.lastIndex { presentsColumn($0) }
    }

    func nextPresentedColumnIndex(after index: Int, in tableView: NSTableView) -> Int? {
        let start = max(0, index + 1)
        guard start < tableView.tableColumns.count else { return nil }
        return tableView.tableColumns[start...].firstIndex { presentsColumn($0) }
    }

    func previousPresentedColumnIndex(before index: Int, in tableView: NSTableView) -> Int? {
        let end = min(max(0, index), tableView.tableColumns.count)
        guard end > 0 else { return nil }
        return tableView.tableColumns[..<end].lastIndex { presentsColumn($0) }
    }

    func detachFromTableView() {
        guard let tableView = attachedTableView else { return }
        let attached = Set(tableView.tableColumns.map(\.identifier))
        for column in pooledColumns where attached.contains(column.identifier) {
            tableView.removeTableColumn(column)
        }
        attachedTableView = nil
    }

    /// - Returns: whether a column's visibility changed. `NSTableColumn.isHidden` moves every column
    ///   after it and is the one geometry change `NSTableView` announces through no notification, so
    ///   the caller has to repaint the drawn body itself. See
    ///   `TableViewCoordinator.columnGeometryDidChange()`.
    @discardableResult
    func reconcile(
        tableView: NSTableView,
        schema: ColumnIdentitySchema,
        columnTypes: [ColumnType],
        columnComments: [String: String] = [:],
        savedLayout: ColumnLayoutState?,
        isEditable: Bool,
        hiddenColumnNames: Set<String>,
        widthCalculator: (String, Int) -> CGFloat
    ) -> Bool {
        attach(to: tableView)
        let visibleCount = schema.columnNames.count
        activeIdentifiers = Set(schema.identifiers)

        growBackingPoolIfNeeded(to: visibleCount)

        let willRestoreWidths = !(savedLayout?.columnWidths.isEmpty ?? true)
        let hiddenFromLayout = savedLayout?.hiddenColumns ?? []
        var comments: [NSUserInterfaceItemIdentifier: String] = [:]
        var showsComments = false
        var visibilityChanged = false

        for slot in 0..<pooledColumns.count {
            let column = pooledColumns[slot]
            if slot < visibleCount {
                let columnName = schema.columnNames[slot]
                let resolvedWidth = willRestoreWidths
                    ? (savedLayout?.columnWidths[columnName] ?? widthCalculator(columnName, slot))
                    : widthCalculator(columnName, slot)
                let comment = displayableComment(columnComments[columnName])
                configureColumn(
                    column,
                    name: columnName,
                    columnType: slot < columnTypes.count ? columnTypes[slot] : nil,
                    comment: comment,
                    width: resolvedWidth,
                    isEditable: isEditable
                )
                let hidden = hiddenFromLayout.contains(columnName) || hiddenColumnNames.contains(columnName)
                if hidden {
                    userHiddenIdentifiers.insert(column.identifier)
                } else {
                    userHiddenIdentifiers.remove(column.identifier)
                }
                visibilityChanged = setHidden(hidden, on: column) || visibilityChanged
                if let comment {
                    comments[column.identifier] = comment
                    if !hidden {
                        showsComments = true
                    }
                }
            } else {
                visibilityChanged = setHidden(true, on: column) || visibilityChanged
            }
        }
        applyComments(comments, showsComments: showsComments, in: tableView)

        let targetOrder = computeTargetOrder(
            visibleCount: visibleCount,
            savedOrder: savedLayout?.columnOrder,
            schema: schema
        )

        attachAndOrderColumns(
            in: tableView,
            visibleCount: visibleCount,
            targetOrder: targetOrder
        )
        return visibilityChanged
    }

    private func setHidden(_ hidden: Bool, on column: NSTableColumn) -> Bool {
        guard column.isHidden != hidden else { return false }
        column.isHidden = hidden
        return true
    }

    private func growBackingPoolIfNeeded(to count: Int) {
        while pooledColumns.count < count {
            let slot = pooledColumns.count
            let column = NSTableColumn(identifier: ColumnIdentitySchema.slotIdentifier(slot))
            column.minWidth = DataGridMetrics.dataColumnMinWidth
            column.maxWidth = DataGridMetrics.dataColumnMaxWidth
            column.resizingMask = .userResizingMask
            column.isEditable = true
            column.isHidden = true
            pooledColumns.append(column)
        }
    }

    private func computeTargetOrder(
        visibleCount: Int,
        savedOrder: [String]?,
        schema: ColumnIdentitySchema
    ) -> [Int] {
        var slots: [Int] = []
        var seen = Set<Int>()

        if let savedOrder {
            for name in savedOrder {
                guard let slot = schema.dataIndex(forColumnName: name),
                      slot < visibleCount,
                      !seen.contains(slot) else { continue }
                slots.append(slot)
                seen.insert(slot)
            }
        }

        for slot in 0..<visibleCount where !seen.contains(slot) {
            slots.append(slot)
        }
        return slots
    }

    private func attachAndOrderColumns(
        in tableView: NSTableView,
        visibleCount: Int,
        targetOrder: [Int]
    ) {
        var attached = Set(tableView.tableColumns.map(\.identifier))
        let baseOffset = tableView.tableColumns.first?.identifier == ColumnIdentitySchema.rowNumberIdentifier ? 1 : 0

        for slot in targetOrder where !attached.contains(pooledColumns[slot].identifier) {
            tableView.addTableColumn(pooledColumns[slot])
            attached.insert(pooledColumns[slot].identifier)
        }

        for slot in 0..<pooledColumns.count
        where slot >= visibleCount && !attached.contains(pooledColumns[slot].identifier) {
            tableView.addTableColumn(pooledColumns[slot])
            attached.insert(pooledColumns[slot].identifier)
        }

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        defer { NSAnimationContext.endGrouping() }

        var indexByIdentifier: [NSUserInterfaceItemIdentifier: Int] = [:]
        indexByIdentifier.reserveCapacity(tableView.tableColumns.count)
        for (index, column) in tableView.tableColumns.enumerated() {
            indexByIdentifier[column.identifier] = index
        }

        for (targetPosition, slot) in targetOrder.enumerated() {
            let identifier = ColumnIdentitySchema.slotIdentifier(slot)
            guard let currentIndex = indexByIdentifier[identifier] else { continue }
            let desiredIndex = baseOffset + targetPosition
            guard desiredIndex < tableView.tableColumns.count else { continue }
            if currentIndex == desiredIndex { continue }

            tableView.moveColumn(currentIndex, toColumn: desiredIndex)
            updateIndexMap(&indexByIdentifier, movedFrom: currentIndex, to: desiredIndex)
        }
    }

    private func updateIndexMap(
        _ map: inout [NSUserInterfaceItemIdentifier: Int],
        movedFrom source: Int,
        to destination: Int
    ) {
        guard source != destination else { return }
        let lower = min(source, destination)
        let upper = max(source, destination)
        let delta = source < destination ? -1 : 1
        for (key, value) in map where value >= lower && value <= upper {
            if value == source {
                map[key] = destination
            } else {
                map[key] = value + delta
            }
        }
    }

    private func configureColumn(
        _ column: NSTableColumn,
        name: String,
        columnType: ColumnType?,
        comment: String?,
        width: CGFloat,
        isEditable: Bool
    ) {
        if !(column.headerCell is SortableHeaderCell) || column.headerCell.stringValue != name {
            let cell = SortableHeaderCell(textCell: name)
            cell.font = column.headerCell.font
            cell.alignment = column.headerCell.alignment
            column.headerCell = cell
        }

        var tooltip: String
        if let typeName = columnType?.rawType ?? columnType?.displayName {
            tooltip = "\(name) (\(typeName))"
        } else {
            tooltip = name
        }
        if let comment {
            tooltip += "\n\(comment)"
        }
        if column.headerToolTip != tooltip {
            column.headerToolTip = tooltip
        }

        let label = accessibilityLabel(name: name, comment: comment)
        if column.headerCell.accessibilityLabel() != label {
            column.headerCell.setAccessibilityLabel(label)
        }

        if column.width != width {
            column.width = width
        }
        if column.isEditable != isEditable {
            column.isEditable = isEditable
        }
        if column.sortDescriptorPrototype?.key != name {
            column.sortDescriptorPrototype = NSSortDescriptor(key: name, ascending: true)
        }
    }

    private func accessibilityLabel(name: String, comment: String?) -> String {
        let label = String(format: String(localized: "Column: %@"), name)
        guard let comment else { return label }
        return "\(label), \(comment)"
    }

    private func displayableComment(_ comment: String?) -> String? {
        guard let comment else { return nil }
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func applyComments(
        _ comments: [NSUserInterfaceItemIdentifier: String],
        showsComments: Bool,
        in tableView: NSTableView
    ) {
        guard let headerView = tableView.headerView as? SortableHeaderView else { return }
        headerView.showsComments = showsComments
        headerView.updateComments(comments)
    }
}
