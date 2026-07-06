//
//  MainContentCoordinator+ExecuteAll.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func runAllStatements() {
        queryExecutionCoordinator.runAllStatements()
    }

    internal func dispatchStatements(_ statements: [String], tabIndex index: Int, bypassRowLimit: Bool = false) {
        queryExecutionCoordinator.dispatchStatements(statements, tabIndex: index, bypassRowLimit: bypassRowLimit)
    }

    internal func dispatchParameterizedStatements(
        _ statements: [String],
        parameters: [QueryParameter],
        tabIndex index: Int,
        bypassRowLimit: Bool = false
    ) {
        queryExecutionCoordinator.dispatchParameterizedStatements(
            statements,
            parameters: parameters,
            tabIndex: index,
            bypassRowLimit: bypassRowLimit
        )
    }
}
