//
//  ConnectionURLFilter.swift
//  TablePro
//

import Foundation

internal enum ConnectionURLFilter: Equatable, Sendable {
    case condition(String)
    case column(name: String, operation: String?, value: String?)

    internal var displayText: String {
        switch self {
        case .condition(let sql):
            return sql
        case .column(let name, let operation, let value):
            return [name, operation, value].compactMap { $0 }.joined(separator: " ")
        }
    }

    internal var filterState: TabFilterState {
        TabFilterState(filters: [tableFilter], commit: .all, isVisible: true, filterLogicMode: .and)
    }

    private var tableFilter: TableFilter {
        switch self {
        case .condition(let sql):
            return TableFilter(columnName: TableFilter.rawSQLColumn, rawSQL: sql)
        case .column(let name, let operation, let value):
            return TableFilter(
                columnName: name,
                filterOperator: Self.filterOperator(forURLOperation: operation ?? "Equal"),
                value: value ?? ""
            )
        }
    }

    private static func filterOperator(forURLOperation operation: String) -> FilterOperator {
        switch operation.lowercased() {
        case "equal", "equals", "=":
            return .equal
        case "not equal", "notequal", "!=":
            return .notEqual
        case "contains", "like":
            return .contains
        case "not contains", "notcontains", "not like":
            return .notContains
        case "starts with", "startswith":
            return .startsWith
        case "ends with", "endswith":
            return .endsWith
        case "greater than", "greaterthan", ">":
            return .greaterThan
        case "greater or equal", "greaterorequal", ">=":
            return .greaterOrEqual
        case "less than", "lessthan", "<":
            return .lessThan
        case "less or equal", "lessorequal", "<=":
            return .lessOrEqual
        case "is null", "isnull":
            return .isNull
        case "is not null", "isnotnull":
            return .isNotNull
        case "is empty", "isempty":
            return .isEmpty
        case "is not empty", "isnotempty":
            return .isNotEmpty
        case "in":
            return .inList
        case "not in", "notin":
            return .notInList
        case "between":
            return .between
        case "regex":
            return .regex
        default:
            return .contains
        }
    }
}

internal extension ParsedConnectionURL {
    /// The filter is applied to the table the link opens, so a link without a table applies none.
    var filter: ConnectionURLFilter? {
        guard tableName != nil else { return nil }
        if let filterCondition, !filterCondition.isEmpty {
            return .condition(filterCondition)
        }
        if let filterColumn, !filterColumn.isEmpty {
            return .column(name: filterColumn, operation: filterOperation, value: filterValue)
        }
        return nil
    }
}
