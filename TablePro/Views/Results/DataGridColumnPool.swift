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
        growPoolIfNeeded(to: visibleCount, in: tableView)

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
                column.isHidden = hiddenFromLayout.contains(columnName) || hiddenColumnNames.contains(columnName)
            } else {
                column.isHidden = true
            }
        }

        resetToNaturalOrder(in: tableView, visibleSlotCount: visibleCount)

        if let order = savedLayout?.columnOrder, !order.isEmpty {
            applyColumnOrder(order, in: tableView, schema: schema)
        }
    }

    func currentSlotForColumnName(_ name: String, in schema: ColumnIdentitySchema) -> Int? {
        schema.dataIndex(forColumnName: name)
    }

    private func growPoolIfNeeded(to count: Int, in tableView: NSTableView) {
        while pooledColumns.count < count {
            let slot = pooledColumns.count
            let column = NSTableColumn(identifier: ColumnIdentitySchema.slotIdentifier(slot))
            column.minWidth = 30
            column.resizingMask = .userResizingMask
            column.isEditable = true
            pooledColumns.append(column)
            tableView.addTableColumn(column)
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

    private func resetToNaturalOrder(in tableView: NSTableView, visibleSlotCount: Int) {
        let rowNumberIsPresent = tableView.tableColumns.first?.identifier == ColumnIdentitySchema.rowNumberIdentifier
        let baseOffset = rowNumberIsPresent ? 1 : 0

        for slot in 0..<visibleSlotCount {
            let identifier = ColumnIdentitySchema.slotIdentifier(slot)
            guard let currentIndex = tableView.tableColumns.firstIndex(where: { $0.identifier == identifier }) else {
                continue
            }
            let desiredIndex = baseOffset + slot
            guard desiredIndex < tableView.tableColumns.count else { continue }
            if currentIndex != desiredIndex {
                tableView.moveColumn(currentIndex, toColumn: desiredIndex)
            }
        }
    }

    private func applyColumnOrder(
        _ order: [String],
        in tableView: NSTableView,
        schema: ColumnIdentitySchema
    ) {
        let rowNumberIsPresent = tableView.tableColumns.first?.identifier == ColumnIdentitySchema.rowNumberIdentifier
        let baseOffset = rowNumberIsPresent ? 1 : 0
        let validOrder = order.filter { schema.dataIndex(forColumnName: $0) != nil }

        for (targetPosition, columnName) in validOrder.enumerated() {
            guard let slot = schema.dataIndex(forColumnName: columnName) else { continue }
            let identifier = ColumnIdentitySchema.slotIdentifier(slot)
            guard let currentIndex = tableView.tableColumns.firstIndex(where: { $0.identifier == identifier }) else {
                continue
            }
            let desiredIndex = baseOffset + targetPosition
            guard desiredIndex < tableView.tableColumns.count else { continue }
            if currentIndex != desiredIndex {
                tableView.moveColumn(currentIndex, toColumn: desiredIndex)
            }
        }
    }
}
