//
//  DataGridViewController+ValueFilter.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

// Each loaded value as the cell shows it, counted, in the order first seen.
struct ColumnValueTally: Sendable {
    var counts: [String: Int] = [:]
    var order: [String] = []
    var nullCount = 0

    func sorted() -> [ColumnDistinctValue] {
        var values = order
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { ColumnDistinctValue(display: $0, isNull: false, count: counts[$0] ?? 0) }
        if nullCount > 0 {
            values.insert(ColumnDistinctValue(display: "", isNull: true, count: nullCount), at: 0)
        }
        return values
    }

    // A column of unique values makes n log n locale-aware comparisons, too slow for the main actor.
    @concurrent
    func sortedOffTheMainActor() async -> [ColumnDistinctValue] {
        sorted()
    }
}

extension DataGridCommands {
    // Every loaded value as the cell shows it, which is what a value filter stores and matches; NULL first.
    func distinctValues(for column: DataGridColumn) -> [ColumnDistinctValue] {
        valueTally(for: column).sorted()
    }

    // Formatting reads main-actor state, so the tally is taken here and only the sort leaves the main actor.
    func valueTally(for column: DataGridColumn) -> ColumnValueTally {
        let rows = model.rows
        let dataIndex = column.dataIndex
        guard dataIndex >= 0, dataIndex < rows.columns.count else { return ColumnValueTally() }
        let format = model.displayFormat(for: column)
        let databaseType = configuration.traits.databaseType
        var tally = ColumnValueTally()
        for row in rows.rows {
            guard dataIndex < row.values.count else { continue }
            let raw = row.values[dataIndex]
            if case .null = raw {
                tally.nullCount += 1
                continue
            }
            let display = GridDisplayOrderResolver.displayValue(
                raw,
                columnType: column.type,
                displayFormat: format,
                databaseType: databaseType
            )
            if tally.counts[display] == nil {
                tally.order.append(display)
            }
            tally.counts[display, default: 0] += 1
        }
        return tally
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
        guard model.anchor(for: column) != nil else { return }

        let tally = gridCommands.valueTally(for: column)
        let initialFilter = model.store.valueFilter.filter(forColumn: dataIndex)
        let loadedRowCount = rows.count
        let listedModel = model
        dismissValueFilterPopover()
        // A reload, insert or removal while the list sorts cancels it, as it would close the open popover.
        menuState.valueFilterListing = Task { [weak self] in
            let values = await tally.sortedOffTheMainActor()
            guard !Task.isCancelled, let self else { return }
            self.menuState.valueFilterListing = nil
            // A grid that took another tab's model meanwhile shows other rows.
            guard self.model === listedModel,
                  let current = self.model.columns.column(id: columnID),
                  let anchor = self.model.anchor(for: current) else { return }
            // A connection switch unparents the grid without dismantling it, and NSPopover raises on a view with no window.
            guard let window = anchor.view.window, window.isVisible else { return }
            self.showValueFilterPopover(
                for: current,
                values: values,
                loadedRowCount: loadedRowCount,
                initialFilter: initialFilter,
                anchor: anchor
            )
        }
    }

    private func showValueFilterPopover(
        for column: DataGridColumn,
        values: [ColumnDistinctValue],
        loadedRowCount: Int,
        initialFilter: ColumnValueFilter?,
        anchor: (view: NSView, rect: NSRect)
    ) {
        let columnID = column.id
        menuState.valueFilterPopover = PopoverPresenter.show(
            relativeTo: anchor.rect,
            of: anchor.view,
            preferredEdge: .maxY
        ) { [weak self] dismiss in
            ColumnValueFilterPopover(
                columnName: column.name,
                values: values,
                loadedRowCount: loadedRowCount,
                initialFilter: initialFilter,
                // A change closes the popover once applied, in followRowChangesWithPopovers; declining the alert keeps the picks.
                onApply: { filter in
                    guard let self, let current = self.model.columns.column(id: columnID) else {
                        dismiss()
                        return
                    }
                    if !self.applyValueFilter(filter, to: current) {
                        dismiss()
                    }
                },
                onCancel: dismiss
            )
        }
    }

    func dismissValueFilterPopover() {
        menuState.valueFilterListing?.cancel()
        menuState.valueFilterListing = nil
        guard let popover = menuState.valueFilterPopover else { return }
        menuState.valueFilterPopover = nil
        popover.close()
    }

    // The model asks the owner to confirm before a change that would drop pending edits; no change asks nothing.
    @discardableResult
    func applyValueFilter(_ filter: ColumnValueFilter?, to column: DataGridColumn) -> Bool {
        var state = model.store.valueFilter
        if let filter {
            state.set(filter, columnName: column.name, forColumn: column.dataIndex)
        } else {
            state.clear(column: column.dataIndex)
        }
        guard state != model.store.valueFilter else { return false }
        model.setValueFilter(state)
        return true
    }

    func clearAllValueFilters() {
        var state = model.store.valueFilter
        guard state.isActive else { return }
        state.clearAll()
        model.setValueFilter(state)
    }
}
