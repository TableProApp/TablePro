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
}
