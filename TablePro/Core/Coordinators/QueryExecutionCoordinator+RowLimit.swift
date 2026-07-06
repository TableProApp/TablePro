//
//  QueryExecutionCoordinator+RowLimit.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct QueryLimitPlan {
    let rowCap: Int?
    let executedSQL: String
}

extension QueryExecutionCoordinator {
    func resolveExecutionPlan(sql: String, tabType: TabType, bypassLimit: Bool = false) -> QueryLimitPlan {
        guard !bypassLimit, let rowCap = resolveRowCap(sql: sql, tabType: tabType) else {
            return QueryLimitPlan(rowCap: nil, executedSQL: sql)
        }
        let overFetchLimit = rowCap + 1
        if let adapter = DatabaseManager.shared.driver(for: parent.connectionId) as? PluginDriverAdapter,
           let injected = adapter.injectRowLimit(sql, limit: overFetchLimit) {
            return QueryLimitPlan(rowCap: rowCap, executedSQL: injected)
        }
        let injection = SQLLimitInjector.inject(
            into: sql,
            limit: overFetchLimit,
            autoLimitStyle: PluginManager.shared.autoLimitStyle(for: parent.connection.type),
            lexicalDialect: parent.sqlDialect
        )
        switch injection {
        case .injected(let injectedSQL):
            return QueryLimitPlan(rowCap: rowCap, executedSQL: injectedSQL)
        case .alreadyLimited:
            return QueryLimitPlan(rowCap: nil, executedSQL: sql)
        case .notInjectable:
            return QueryLimitPlan(rowCap: rowCap, executedSQL: sql)
        }
    }
}
