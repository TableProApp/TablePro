//
//  ColumnTypeSQLQuoting.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum ColumnTypeSQLQuoting {
    static func booleanSynonym(for value: String) -> PluginBooleanSynonym? {
        PluginSQLLiteral.booleanSynonym(for: value)
    }

    static func isNumericLiteral(_ value: String, for type: ColumnType?) -> Bool {
        guard let type else {
            return Int(value) != nil || Double(value) != nil
        }
        switch type {
        case .integer:
            return RowValueCopyFormatter.isIntegerLiteral(value)
        case .decimal:
            return PluginNumericLiteral.isValid(value)
        case .text, .date, .timestamp, .datetime, .boolean, .blob, .json, .enumType, .set, .spatial, .array:
            return false
        }
    }

    static func isKnownTextLike(_ type: ColumnType?) -> Bool {
        guard let type else { return false }
        switch type {
        case .text, .enumType, .set, .array:
            return true
        case .integer, .decimal, .date, .timestamp, .datetime, .boolean, .blob, .json, .spatial:
            return false
        }
    }

    static func supportsEmptyStringComparison(_ type: ColumnType?) -> Bool {
        guard let type else { return true }
        return isKnownTextLike(type)
    }

    static func lookupByName(columns: [String], columnTypes: [ColumnType]) -> [String: ColumnType] {
        var lookup: [String: ColumnType] = [:]
        for (index, name) in columns.enumerated() where columnTypes.indices.contains(index) {
            guard lookup[name] == nil else { continue }
            lookup[name] = columnTypes[index]
        }
        return lookup
    }
}
