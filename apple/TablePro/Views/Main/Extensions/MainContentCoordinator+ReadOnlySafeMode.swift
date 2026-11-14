//
//  MainContentCoordinator+ReadOnlySafeMode.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

extension MainContentCoordinator {
    // The gate's own answer, read as a run starts, so every read the app sends for the user carries the level its
    // approval was given under: a view or a row security policy can call a writing function with no call in the text.
    var runsAtReadOnly: Bool {
        ExecutionGateProvider.runsAtReadOnly(connectionId, in: services.databaseManager)
    }

    // What the tab's query was built from, and what its next page or count runs.
    static func browseFilters(_ filterState: TabFilterState) -> [TableFilter] {
        filterState.executedFilters + filterState.rerunFilters.filters
    }

    static func rawFilterExpressions(_ filters: [TableFilter]) -> [String] {
        filters.filter { $0.isEnabled && $0.isRawSQL }.map(\.value)
    }

    // A raw filter is text the user typed, inside a query no gate reads below the Full levels. At Read-Only, where the
    // driver cannot hold the engine to read-only, one that calls a function goes to the gate, which refuses it, before
    // a browse, page turn, sort or count sends it. On Oracle and Dameng a bare name can call one too, and only the
    // catalog the gate reads against the whole query can tell it from a column, so every raw filter goes there.
    func rawFilterNeedsReadOnlyGate(_ filters: [TableFilter]) -> Bool {
        let expressions = Self.rawFilterExpressions(filters)
        guard !expressions.isEmpty, runsAtReadOnly,
              ExecutionGateProvider.readOnlyFunctionPolicy(
                  connectionId: connectionId, databaseType: connection.type, in: services.databaseManager
              ).functionsCanWrite
        else { return false }
        if SQLBareNameCalls.engines.contains(connection.type.rawValue) { return true }
        return expressions.contains { ReadOnlyFunctionCalls.callsUnlistedFunction($0, databaseType: connection.type) }
    }

    func rawFilterRequest(sql: String, canPrompt: Bool, scope: DatabaseScope?) -> OperationRequest {
        OperationRequest(
            connectionId: connectionId,
            databaseType: connection.type,
            sql: sql,
            kind: .readQuery,
            caller: .userInterface,
            capabilities: canPrompt ? .interactiveUser : CallerCapabilities.interactiveUser.union(.cannotPrompt),
            operationDescription: String(localized: "Execute Query"),
            runsIn: scope
        )
    }
}
