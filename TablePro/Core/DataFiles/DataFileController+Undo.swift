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
            filterState: includesFilters ? filterState : nil,
            queryRevision: queryRevision
        )
    }

    func commit(
        _ updated: TabularTable,
        actionName: String,
        displayKeys newDisplayKeys: [Int]?? = nil,
        includesFilters: Bool = false,
        adjust: ((DataFileController) -> Void)? = nil
    ) {
        guard let previous = captureEditState(queryRevision: currentQueryRevision, includesFilters: includesFilters) else {
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
        let includesFilters = state.filterState != nil
        guard let current = captureEditState(queryRevision: currentQueryRevision, includesFilters: includesFilters) else {
            return
        }
        let sortBefore = sortState
        replaceTable(state.table)
        for (id, kind) in state.inferredKinds {
            setInferredKind(kind, for: id)
        }
        kindOverrides = state.kindOverrides
        columnLayout = state.columnLayout
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
        if find.isVisible, find.hasQuery {
            scheduleFind()
        }
    }
}
