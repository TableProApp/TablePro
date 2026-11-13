//
//  PaginationCoordinator+CappedRead.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension PaginationCoordinator {
    // Fetch All's gate and driver read, capped and handed back rather than installed, for a reader such as Share
    // Result that needs more rows than the grid holds without changing what the grid shows.
    internal func readRows(
        tabId: UUID,
        query: String,
        parameters: [TypedParameterValue?]?,
        rowCap: Int,
        operationDescription: String
    ) async throws -> QueryResult {
        guard let tab = parent.tabManager.tabs.first(where: { $0.id == tabId }),
              let scope = parent.scope(for: tab)
        else { throw DatabaseError.notConnected }


        let workToken = parent.tabExecution.beginUnclaimedWork(for: tabId)
        defer { parent.tabExecution.endUnclaimedWork(workToken, for: tabId) }

        let decision = await parent.executionGate.authorize(OperationRequest(
            connectionId: scope.connectionId,
            databaseType: parent.connection.type,
            sql: query,
            kind: .readQuery,
            caller: .userInterface,
            capabilities: .interactiveUser,
            operationDescription: operationDescription,
            scope: scope
        ))
        if let denial = decision.denialError { throw denial }

        let isTableTab = tab.tabType == .table
        let lengthColumns = isTableTab ? parent.unloadedValueLengthColumns(for: tab) : []
        let safeModeIsReadOnly = parent.runsAtReadOnly
        return try await parent.withExecutionDriver(scope: scope, isTableTab: isTableTab, lease: DriverLeaseOwner()) { driver in
            let values = parameters.map { $0.map { $0 as Any? } }
            let result: QueryResult
            if let context = driver.readOnlyRunContext(safeModeIsReadOnly: safeModeIsReadOnly) {
                result = try await driver.executeUserQuery(
                    query: query, rowCap: rowCap, parameters: values, context: context
                )
            } else {
                result = try await driver.executeUserQuery(query: query, rowCap: rowCap, parameters: values)
            }
            return result.foldingUnloadedValues(lengthColumns: lengthColumns)
        }
    }
}
