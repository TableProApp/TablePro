//
//  DataFileFilterMapping.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProTabular

enum DataFileFilterMapping {
    static func comparison(for filterOperator: FilterOperator) -> TabularComparison {
        switch filterOperator {
        case .equal: return .equal
        case .notEqual: return .notEqual
        case .contains: return .contains
        case .notContains: return .notContains
        case .startsWith: return .startsWith
        case .endsWith: return .endsWith
        case .greaterThan: return .greaterThan
        case .greaterOrEqual: return .greaterOrEqual
        case .lessThan: return .lessThan
        case .lessOrEqual: return .lessOrEqual
        case .isNull: return .isNull
        case .isNotNull: return .isNotNull
        case .isEmpty: return .isEmpty
        case .isNotEmpty: return .isNotEmpty
        case .inList: return .inList
        case .notInList: return .notInList
        case .between: return .between
        case .regex: return .regex
        }
    }

    static func operand(_ raw: String, allowsNullLiteral: Bool) -> TabularOperand {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let number: Double? = PluginNumericLiteral.isValid(trimmed) ? Double(trimmed) : nil
        return TabularOperand(
            text: raw,
            number: number,
            boolean: StoredBoolean.value(of: trimmed),
            isNullLiteral: allowsNullLiteral && trimmed.caseInsensitiveCompare("NULL") == .orderedSame
        )
    }

    static func listItems(_ input: String) -> [String] {
        input.split(separator: ",", omittingEmptySubsequences: true).compactMap {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
