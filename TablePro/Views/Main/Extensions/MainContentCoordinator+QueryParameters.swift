//
//  MainContentCoordinator+QueryParameters.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    func detectAndReconcileParameters(sql: String, existing: [QueryParameter]) -> [QueryParameter] {
        queryExecutionCoordinator.detectAndReconcileParameters(sql: sql, existing: existing)
    }

    func executeQueryWithParameters(_ sql: String, parameters: [QueryParameter]) {
        queryExecutionCoordinator.executeQueryWithParameters(sql, parameters: parameters)
    }

    internal func executeQueryInternalParameterized(
        _ sql: String,
        parameters: [Any?],
        originalParameters: [QueryParameter]
    ) {
        queryExecutionCoordinator.executeQueryInternalParameterized(
            sql,
            parameters: parameters,
            originalParameters: originalParameters
        )
    }

    func executeMultipleStatementsWithParameters(_ statements: [String], parameters: [QueryParameter]) {
        queryExecutionCoordinator.executeMultipleStatementsWithParameters(statements, parameters: parameters)
    }
}
