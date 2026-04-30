//
//  DataGridColumnPool.swift
//  TablePro
//

import AppKit

@MainActor
final class DataGridColumnPool {
    private var pooledColumns: [NSTableColumn] = []
    private weak var attachedTableView: NSTableView?

    var totalSlots: Int { pooledColumns.count }

    func attach(to tableView: NSTableView) {
        attachedTableView = tableView
    }

    func detachFromTableView() {
        guard let tableView = attachedTableView else { return }
        for column in pooledColumns where tableView.tableColumns.contains(column) {
            tableView.removeTableColumn(column)
        }
        attachedTableView = nil
    }

    func reconcile(
        tableView: NSTableView,
        schema: ColumnIdentitySchema,
        columnTypes: [ColumnType],
        savedLayout: ColumnLayoutState?,
        isEditable: Bool,
        hiddenColumnNames: Set<String>,
        widthCalculator: (String, Int) -> CGFloat
    ) {
        attach(to: tableView)
        let visibleCount = schema.columnNames.count

        growBackingPoolIfNeeded(to: visibleCount)

        let willRestoreWidths = !(savedLayout?.columnWidths.isEmpty ?? true)
        let hiddenFromLayout = savedLayout?.hiddenColumns ?? []

        for slot in 0..<pooledColumns.count {
            let column = pooledColumns[slot]
            if slot < visibleCount {
                let columnName = schema.columnNames[slot]
                let resolvedWidth = willRestoreWidths
                    ? (savedLayout?.columnWidths[columnName] ?? 100)
                    : widthCalculator(columnName, slot)
                configureColumn(
                    column,
                    name: columnName,
                    columnType: slot < columnTypes.count ? columnTypes[slot] : nil,
                    width: resolvedWidth,
                    isEditable: isEditable
                )
                let hidden = hiddenFromLayout.contains(columnName) || hiddenColumnNames.contains(columnName)
                if column.isHidden != hidden {
                    column.isHidden = hidden
                }
            } else if !column.isHidden {
                column.isHidden = true
            }
        }

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
    }

    private func growBackingPoolIfNeeded(to count: Int) {
        while pooledColumns.count < count {
            let slot = pooledColumns.count
            let column = NSTableColumn(identifier: ColumnIdentitySchema.slotIdentifier(slot))
            column.minWidth = 30
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
        width: CGFloat,
        isEditable: Bool
    ) {
        if !(column.headerCell is SortableHeaderCell) || column.headerCell.stringValue != name {
            let cell = SortableHeaderCell(textCell: name)
            cell.font = column.headerCell.font
            cell.alignment = column.headerCell.alignment
            column.headerCell = cell
        }

        let tooltip: String
        if let typeName = columnType?.rawType ?? columnType?.displayName {
            tooltip = "\(name) (\(typeName))"
        } else {
            tooltip = name
        }
        if column.headerToolTip != tooltip {
            column.headerToolTip = tooltip
        }

        let label = String(format: String(localized: "Column: %@"), name)
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
}
