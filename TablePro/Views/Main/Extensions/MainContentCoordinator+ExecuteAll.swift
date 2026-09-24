//
//  MainContentCoordinator+ExecuteAll.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func runAllStatements(extraCapabilities: CallerCapabilities = []) {
        queryExecutionCoordinator.runAllStatements(extraCapabilities: extraCapabilities)
    }

    internal func dispatchBatches(
        _ batches: [ExecutableBatch],
        tabIndex index: Int,
        bypassRowLimit: Bool = false
    ) {
        queryExecutionCoordinator.dispatchBatches(batches, tabIndex: index, bypassRowLimit: bypassRowLimit)
    }

    internal func dispatchParameterizedBatches(
        _ batches: [ExecutableBatch],
        parameters: [QueryParameter],
        tabIndex index: Int,
        bypassRowLimit: Bool = false
    ) {
        queryExecutionCoordinator.dispatchParameterizedBatches(
            batches,
            parameters: parameters,
            tabIndex: index,
            bypassRowLimit: bypassRowLimit
        )
    }
}
