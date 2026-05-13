//
//  MainContentCoordinator+ExecuteAll.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func runAllStatements() {
        queryExecutionCoordinator.runAllStatements()
    }

    internal func dispatchStatements(_ statements: [String], tabIndex index: Int) {
        queryExecutionCoordinator.dispatchStatements(statements, tabIndex: index)
    }

    internal func dispatchParameterizedStatements(
        _ statements: [String],
        parameters: [QueryParameter],
        tabIndex index: Int
    ) {
        queryExecutionCoordinator.dispatchParameterizedStatements(
            statements,
            parameters: parameters,
            tabIndex: index
        )
    }
}
