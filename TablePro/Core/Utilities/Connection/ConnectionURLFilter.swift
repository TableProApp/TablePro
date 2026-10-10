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
