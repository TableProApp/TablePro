import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit

// What the browser asks for one page of a table, with only the filters that apply.
nonisolated struct TableReadRequest: Sendable {
    let table: String
    let schema: String?
    let filters: [TableFilter]
    let logicMode: FilterLogicMode
    let searchText: String?
    let searchColumns: [String]
    let sortState: SortState
}

// A document store pages, filters, counts and looks values up in its own language, which SQLBuilder cannot write.
nonisolated protocol DriverQueryBuilding: DatabaseDriver {
    var filterOperators: [FilterOperator] { get }

    func pageQuery(_ request: TableReadRequest, limit: Int, offset: Int) -> String

    func rowCount(_ request: TableReadRequest) async throws -> Int?

    // Throws CellLookupError.rowNotFound when no row holds the key.
    func storedValue(
        table: String,
        schema: String?,
        column: String,
        key: [(column: String, value: String)]
    ) async throws -> String?
}

nonisolated extension FilterOperator {
    // The operator as a plugin's builder reads it, the Mac filter's spelling. LIKE patterns have no plugin form.
    var pluginOperator: String? {
        switch self {
        case .equal: "="
        case .notEqual: "!="
        case .greaterThan: ">"
        case .greaterThanOrEqual: ">="
        case .lessThan: "<"
        case .lessThanOrEqual: "<="
        case .isNull: "IS NULL"
        case .isNotNull: "IS NOT NULL"
        case .in: "IN"
        case .notIn: "NOT IN"
        case .between: "BETWEEN"
        case .contains: "CONTAINS"
        case .startsWith: "STARTS WITH"
        case .endsWith: "ENDS WITH"
        case .like, .notLike: nil
        }
    }
}

nonisolated extension TableFilter {
    var pluginFilter: PluginQueryFilter? {
        guard let op = filterOperator.pluginOperator else { return nil }
        let isBetween = filterOperator == .between
        return PluginQueryFilter(
            column: columnName,
            op: op,
            value: isBetween ? "\(value),\(secondValue)" : value,
            isCaseSensitive: isCaseSensitive,
            secondValue: isBetween ? secondValue : nil,
            elementScope: nil
        )
    }
}
