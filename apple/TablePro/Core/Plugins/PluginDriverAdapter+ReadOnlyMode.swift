//
//  PluginDriverAdapter+ReadOnlyMode.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PluginDriverAdapter {
    var enforcesReadOnlyMode: Bool {
        pluginDriver.capabilities.contains(.enforcesReadOnlyMode)
    }

    func executeBoundedQuery(query: String, rowCap: Int, context: PluginStatementContext) async throws -> QueryResult? {
        try StatementTextValidator.validate(query)
        try refuseUnenforcedPolicy(context)
        guard let pluginResult = try await pluginDriver.executeBoundedQuery(
            query: query,
            rowCap: rowCap,
            context: statementContext(query, approvedAs: context)
        ) else {
            return nil
        }
        return mapQueryResult(pluginResult)
    }
}
