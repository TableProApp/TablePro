//
//  DataFileController+Undo.swift
//  TablePro
//

import Foundation
import TableProTabular

struct DataFileSortReference: Equatable {
    let column: TabularColumnID
    let direction: SortDirection
}

struct DataFileEditState {
    let table: TabularTable
    let inferredKinds: [TabularColumnID: TabularInferredKind]
    let kindOverrides: [TabularColumnID: TabularInferredKind]
    let displayKeys: [Int]?
    let columnLayout: ColumnLayoutState
    let displayFormats: [TabularColumnID: ValueDisplayFormat]
    let filterState: TabFilterState?
    let queryRevision: Int
}

extension DataFileController {
    func captureEditState(queryRevision: Int, includesFilters: Bool = false) -> DataFileEditState? {
        guard let table else { return nil }
        return DataFileEditState(
            table: table,
            inferredKinds: inferredKinds,
            kindOverrides: kindOverrides,
            displayKeys: displayKeys,
            columnLayout: columnLayout,
            displayFormats: displayFormatsByColumn,
            filterState: includesFilters ? filterState : nil,
            queryRevision: queryRevision
        )
    }

    func commit(
        _ updated: TabularTable,
        actionName: String,
        displayKeys newDisplayKeys: [Int]?? = nil,
        adjust: ((DataFileController) -> Void)? = nil
    ) {
        // Removing a column takes the filter rows on it, so undo has to bring them back.
        let dropsFilters = dropsFilterRows(updated)
        let rerunsQuery = dropsFilterRows(updated, appliedOnly: true)
            || sortReferences.contains { table?.columnIndex(of: $0.column) != nil && updated.columnIndex(of: $0.column) == nil }
        guard let previous = captureEditState(queryRevision: currentQueryRevision, includesFilters: dropsFilters) else {
            return
        }
        replaceTable(updated)
        if let newDisplayKeys {
            setDisplayKeys(newDisplayKeys)
        }
        adjust?(self)
        registerUndo(restoring: previous, actionName: actionName)
        onEdited?()
        refreshPage()
        if rerunsQuery {
            runQuery()
        }
    }

    private func registerUndo(restoring state: DataFileEditState, actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated {
                controller.restore(state, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }

    private func restore(_ state: DataFileEditState, actionName: String) {
        // Undoing an insert drops the filter rows on that column, so redo has to bring them back.
        let includesFilters = state.filterState != nil || dropsFilterRows(state.table)
        guard let current = captureEditState(queryRevision: currentQueryRevision, includesFilters: includesFilters) else {
            return
        }
        let sortBefore = sortState
        let returning = Set(state.table.columns.map(\.id)).subtracting(columnNames.ids)
        replaceTable(state.table)
        for (id, kind) in state.inferredKinds {
            setInferredKind(kind, for: id)
        }
        kindOverrides = state.kindOverrides
        // Columns still here keep the layout and Display As set since; only the ones the undo brings back take theirs.
        columnLayout = columnLayout.restoringColumns(
            Set(returning.compactMap { columnNames.name(for: $0) }),
            from: state.columnLayout
        )
        restoreDisplayFormats(state.displayFormats, for: returning)
        if let filters = state.filterState {
            filterState = filters
        }
        registerUndo(restoring: current, actionName: actionName)
        onEdited?()
        if state.queryRevision == currentQueryRevision, !includesFilters, sortState == sortBefore {
            setDisplayKeys(state.displayKeys)
            refreshPage()
        } else {
            runQuery()
        }
    }

    private var displayFormatsByColumn: [TabularColumnID: ValueDisplayFormat] {
        let formats = gridModel.store.displayFormats
        var byColumn: [TabularColumnID: ValueDisplayFormat] = [:]
        for (index, id) in columnNames.ids.enumerated() where index < formats.count {
            if let format = formats[index] {
                byColumn[id] = format
            }
        }
        return byColumn
    }

    private func restoreDisplayFormats(_ saved: [TabularColumnID: ValueDisplayFormat], for ids: Set<TabularColumnID>) {
        var formats = gridModel.store.displayFormats
        for id in ids {
            guard let format = saved[id], let index = columnNames.index(of: id) else { continue }
            formats = DisplayFormatArray.setting(format, at: index, in: formats, columnCount: columnNames.count)
        }
        if formats != gridModel.store.displayFormats {
            gridModel.store.displayFormats = formats
        }
    }
}
