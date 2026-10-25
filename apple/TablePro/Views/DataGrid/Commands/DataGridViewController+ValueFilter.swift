//
//  DataGridViewController+ValueFilter.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

extension DataGridCommands {
    // Every loaded value as the cell shows it, which is what a value filter stores and matches; NULL first.
    func distinctValues(for column: DataGridColumn) -> [ColumnDistinctValue] {
        let rows = model.rows
        let dataIndex = column.dataIndex
        guard dataIndex >= 0, dataIndex < rows.columns.count else { return [] }
        let format = model.displayFormat(for: column)
        let databaseType = configuration.traits.databaseType
        var counts: [String: Int] = [:]
        var order: [String] = []
        var nullCount = 0
        for row in rows.rows {
            guard dataIndex < row.values.count else { continue }
            let raw = row.values[dataIndex]
            if case .null = raw {
                nullCount += 1
                continue
            }
            let display = GridDisplayOrderResolver.displayValue(
                raw,
                columnType: column.type,
                displayFormat: format,
                databaseType: databaseType
            )
            if counts[display] == nil {
                order.append(display)
            }
            counts[display, default: 0] += 1
        }
        var values = order
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { ColumnDistinctValue(display: $0, isNull: false, count: counts[$0] ?? 0) }
        if nullCount > 0 {
            values.insert(ColumnDistinctValue(display: "", isNull: true, count: nullCount), at: 0)
        }
        return values
    }
}

extension DataGridViewController {
    // Opened from the header menu, and from an active filter's funnel; values still on the server load first.
    func presentValueFilter(for column: DataGridColumn) {
        guard offersValueFilter else { return }
        let rows = model.rows
        let dataIndex = column.dataIndex
        let unloaded = rows.rows.filter { $0.unloadedByteCount(dataIndex) != nil }.map(\.id)
        let columnID = column.id
        guard menuState.loader.ensureLoaded(unloaded, columns: IndexSet(integer: dataIndex), in: model, retry: { [weak self] in
            guard let self, let current = self.model.columns.column(id: columnID) else { return }
            self.presentValueFilter(for: current)
        }) else { return }
        guard let anchor = model.anchor(for: column) else { return }

        let values = gridCommands.distinctValues(for: column)
        let initialFilter = model.store.valueFilter.filter(forColumn: dataIndex)
        dismissValueFilterPopover()
        menuState.valueFilterPopover = PopoverPresenter.show(
            relativeTo: anchor.rect,
            of: anchor.view,
            preferredEdge: .maxY
        ) { [weak self] dismiss in
            ColumnValueFilterPopover(
                columnName: column.name,
                values: values,
                loadedRowCount: rows.count,
                initialFilter: initialFilter,
                onApply: { filter in
                    dismiss()
                    guard let self, let current = self.model.columns.column(id: columnID) else { return }
                    self.applyValueFilter(filter, to: current)
                },
                onCancel: dismiss
            )
        }
    }

    func dismissValueFilterPopover() {
        guard let popover = menuState.valueFilterPopover else { return }
        menuState.valueFilterPopover = nil
        popover.close()
    }

    // The model asks the owner to confirm before a change that would drop pending edits; no change asks nothing.
    func applyValueFilter(_ filter: ColumnValueFilter?, to column: DataGridColumn) {
        var state = model.store.valueFilter
        if let filter {
            state.set(filter, columnName: column.name, forColumn: column.dataIndex)
        } else {
            state.clear(column: column.dataIndex)
        }
        model.setValueFilter(state)
    }

    func clearAllValueFilters() {
        var state = model.store.valueFilter
        guard state.isActive else { return }
        state.clearAll()
        model.setValueFilter(state)
    }
}
