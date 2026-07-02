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
        return QueryLimitPlan(rowCap: rowCap, executedSQL: limitedSQL(for: sql, rowCap: rowCap))
    }

    private func limitedSQL(for sql: String, rowCap: Int) -> String {
        let overFetchLimit = rowCap + 1
        if let adapter = DatabaseManager.shared.driver(for: parent.connectionId) as? PluginDriverAdapter,
           let injected = adapter.injectRowLimit(sql, limit: overFetchLimit) {
            return injected
        }
        let injected = SQLLimitInjector.inject(
            into: sql,
            limit: overFetchLimit,
            autoLimitStyle: PluginManager.shared.autoLimitStyle(for: parent.connection.type),
            lexicalDialect: parent.sqlDialect
        )
        return injected ?? sql
    }
}
