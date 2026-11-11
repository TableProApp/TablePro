//
//  MainContentCoordinator+ReadOnlySafeMode.swift
//  TablePro
//

import Foundation

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

    private static func rawFilterKey(_ filters: [TableFilter]) -> String {
        Set(rawFilterExpressions(filters)).sorted().joined(separator: "\n")
    }

    // A raw filter is text the user typed, inside a query no gate reads below the Full levels. At Read-Only one that
    // calls a function goes to the gate before the browse or a count sends it, and the gate asks where the driver cannot
    // hold the engine to read-only. Once per filter text and tab: its page turns, sorts and counts run what was approved.
    func rawFilterNeedsReadOnlyGate(_ filters: [TableFilter], tabId: UUID) -> Bool {
        let expressions = Self.rawFilterExpressions(filters)
        guard !expressions.isEmpty, runsAtReadOnly, approvedReadOnlyRawFilters[tabId] != Self.rawFilterKey(filters)
        else { return false }
        return expressions.contains { ReadOnlyFunctionCalls.callsUnlistedFunction($0, databaseType: connection.type) }
    }

    func approveReadOnlyRawFilter(_ filters: [TableFilter], tabId: UUID) {
        approvedReadOnlyRawFilters[tabId] = Self.rawFilterKey(filters)
    }

    func rawFilterRequest(sql: String, canPrompt: Bool) -> OperationRequest {
        OperationRequest(
            connectionId: connectionId,
            databaseType: connection.type,
            sql: sql,
            kind: .readQuery,
            caller: .userInterface,
            capabilities: canPrompt ? .interactiveUser : CallerCapabilities.interactiveUser.union(.cannotPrompt),
            operationDescription: String(localized: "Execute Query")
        )
    }
}
