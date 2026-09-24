//
//  DataFileController+Undo.swift
//  TablePro
//

import Foundation
import TableProTabular

struct DataFileEditState {
    let table: TabularTable
    let inferredKinds: [TabularColumnID: TabularInferredKind]
    let kindOverrides: [TabularColumnID: TabularInferredKind]
    let displayKeys: [Int]?
    let columnLayout: ColumnLayoutState
    let queryRevision: Int
}

extension DataFileController {
    func captureEditState(queryRevision: Int) -> DataFileEditState? {
        guard let table else { return nil }
        return DataFileEditState(
            table: table,
            inferredKinds: inferredKinds,
            kindOverrides: kindOverrides,
            displayKeys: displayKeys,
            columnLayout: columnLayout,
            queryRevision: queryRevision
        )
    }

    func commit(
        _ updated: TabularTable,
        actionName: String,
        displayKeys newDisplayKeys: [Int]?? = nil,
        adjust: ((DataFileController) -> Void)? = nil
    ) {
        guard let previous = captureEditState(queryRevision: currentQueryRevision) else { return }
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
        guard let current = captureEditState(queryRevision: currentQueryRevision) else { return }
        replaceTable(state.table)
        for (id, kind) in state.inferredKinds {
            setInferredKind(kind, for: id)
        }
        kindOverrides = state.kindOverrides
        columnLayout = state.columnLayout
        registerUndo(restoring: current, actionName: actionName)
        onEdited?()
        if state.queryRevision == currentQueryRevision {
            setDisplayKeys(state.displayKeys)
            refreshPage()
        } else {
            runQuery()
        }
    }
}
