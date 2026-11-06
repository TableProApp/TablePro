//
//  ExplainResultSetFactory.swift
//  TablePro
//
//  Builds the result set an EXPLAIN produces. Both entry points, the Explain action and a
//  hand-typed statement, go through here so a plan looks the same however it was asked for.
//

import Foundation
import TableProPluginKit

@MainActor
enum ExplainResultSetFactory {
    static func make(
        rawText: String,
        plan: QueryPlan?,
        sql: String?,
        executionTime: TimeInterval?,
        anchor: StatementAnchor? = nil,
        planContext: QueryPlanContext? = nil,
        serverOutput: PluginServerOutput = .none
    ) -> ResultSet {
        let resultSet = ResultSet(label: String(localized: "Plan"))
        resultSet.explainRawText = rawText
        resultSet.queryPlan = plan
        resultSet.baseQuery = sql
        resultSet.executionTime = executionTime
        resultSet.statementAnchor = anchor
        resultSet.explainPlanContext = planContext
        resultSet.serverOutput = serverOutput
        return resultSet
    }
}
