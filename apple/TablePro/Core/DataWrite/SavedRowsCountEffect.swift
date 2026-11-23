//
//  SavedRowsCountEffect.swift
//  TablePro
//

import Foundation

// What a successful save does to the row total its tab shows.
enum SavedRowsCountEffect: Equatable {
    // No row can have come or gone: the total and the scope it settled stay, and the reload counts nothing.
    case keep
    // The count may have moved on a table too large to count: the total stays as an estimate, which the next count skips.
    case estimate
    // Recount as before.
    case retire

    struct Tab: Equatable {
        let tableName: String?
        let schemaName: String?
        let narrowsRows: Bool
        let showsTruncatedTable: Bool
        let totalRowCount: Int?
    }

    // `triggers` is nil when the list for the save's scope is not loaded, or the engine lists none.
    static func effect(of plan: DataWritePlan, on tab: Tab, threshold: Int, triggers: [TriggerInfo]?) -> Self {
        guard !tab.narrowsRows, !tab.showsTruncatedTable else { return .retire }
        if keepsRowCount(plan, tableName: tab.tableName, schemaName: tab.schemaName, triggers: triggers) {
            return .keep
        }
        if let total = tab.totalRowCount, total >= threshold { return .estimate }
        return .retire
    }

    // Updates only, each one recorded, on the tab's own table, with no trigger there: an update through a view can
    // move a row out of its predicate, and a trigger can insert or delete.
    private static func keepsRowCount(
        _ plan: DataWritePlan,
        tableName: String?,
        schemaName: String?,
        triggers: [TriggerInfo]?
    ) -> Bool {
        guard plan.viewTarget == nil, let tableName, let triggers,
              !plan.rowOperations.isEmpty,
              plan.rowOperations.allSatisfy({ $0.kind == .update && $0.target.table == tableName }),
              plan.steps.allSatisfy({ $0.kind != .rowWrite || $0.rowKind == .update })
        else { return false }
        return !triggers.contains { firesOn($0, table: tableName, schema: schemaName) }
    }

    // A spelling the server folds (MySQL `lower_case_table_names`, SQLite) or a name missing from the row counts as a
    // match, so a doubt recounts.
    private static func firesOn(_ trigger: TriggerInfo, table: String, schema: String?) -> Bool {
        let tableMatches = trigger.table.map { $0.caseInsensitiveCompare(table) == .orderedSame } ?? true
        let schemaMatches = trigger.schema.flatMap { listed in
            schema.map { listed.caseInsensitiveCompare($0) == .orderedSame }
        } ?? true
        return tableMatches && schemaMatches
    }
}
