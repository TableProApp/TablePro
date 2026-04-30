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
        widthCalculator: (String, Int) -> CGFloat,
        sortKeyForColumnName: (String) -> String
    ) {
        attach(to: tableView)
        let visibleCount = schema.columnNames.count
        growPoolIfNeeded(to: visibleCount, in: tableView)

        let willRestoreWidths = !(savedLayout?.columnWidths.isEmpty ?? true)
        let hidden = savedLayout?.hiddenColumns ?? []

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
                    sortKey: sortKeyForColumnName(columnName)
                )
                column.isHidden = hidden.contains(columnName)
            } else {
                column.isHidden = true
            }
        }

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
        sortKey: String
    ) {
        let cell = SortableHeaderCell(textCell: name)
        cell.font = column.headerCell.font
        cell.alignment = column.headerCell.alignment
        column.headerCell = cell

        if let typeName = columnType?.rawType ?? columnType?.displayName {
            column.headerToolTip = "\(name) (\(typeName))"
        } else {
            column.headerToolTip = name
        }
        column.headerCell.setAccessibilityLabel(
            String(format: String(localized: "Column: %@"), name)
        )
        column.width = width
        column.sortDescriptorPrototype = NSSortDescriptor(key: sortKey, ascending: true)
    }

    private func applyColumnOrder(
        _ order: [String],
        in tableView: NSTableView,
        schema: ColumnIdentitySchema
    ) {
        let rowNumberIsPresent = tableView.tableColumns.first?.identifier == ColumnIdentitySchema.rowNumberIdentifier
        let baseOffset = rowNumberIsPresent ? 1 : 0

        for (targetPosition, columnName) in order.enumerated() {
            guard let slot = schema.dataIndex(forColumnName: columnName) else { continue }
            let identifier = ColumnIdentitySchema.slotIdentifier(slot)
            guard let currentIndex = tableView.tableColumns.firstIndex(where: { $0.identifier == identifier }) else {
                continue
            }
            let desiredIndex = baseOffset + targetPosition
            if currentIndex != desiredIndex {
                tableView.moveColumn(currentIndex, toColumn: desiredIndex)
            }
        }
    }
}
