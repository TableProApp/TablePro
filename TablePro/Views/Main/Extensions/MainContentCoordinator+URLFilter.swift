//
//  MainContentCoordinator+URLFilter.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    func applyURLFilter(condition: String?, column: String?, operation: String?, value: String?) {
        if let condition, !condition.isEmpty {
            let filter = TableFilter(
                id: UUID(),
                columnName: TableFilter.rawSQLColumn,
                filterOperator: .equal,
                value: "",
                isSelected: true,
                isEnabled: true,
                rawSQL: condition
            )
            applySingleFilter(filter)
            return
        }

        guard let column, !column.isEmpty else { return }

        let filterOp = mapTablePlusOperation(operation ?? "Equal")
        let filter = TableFilter(
            id: UUID(),
            columnName: column,
            filterOperator: filterOp,
            value: value ?? "",
            isSelected: true,
            isEnabled: true
        )
        applySingleFilter(filter)
    }

    private func mapTablePlusOperation(_ operation: String) -> FilterOperator {
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
