//
//  MainContentCoordinator+URLFilter.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func applyURLFilter(_ filter: ConnectionURLFilter) {
        switch filter {
        case .condition(let sql):
            applySingleFilter(TableFilter(
                id: UUID(),
                columnName: TableFilter.rawSQLColumn,
                filterOperator: .equal,
                value: "",
                isEnabled: true,
                rawSQL: sql
            ))
        case .column(let name, let operation, let value):
            applySingleFilter(TableFilter(
                id: UUID(),
                columnName: name,
                filterOperator: filterOperator(forURLOperation: operation ?? "Equal"),
                value: value ?? "",
                isEnabled: true
            ))
        }
    }

    private func filterOperator(forURLOperation operation: String) -> FilterOperator {
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
