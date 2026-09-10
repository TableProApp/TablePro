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
        case .text, .enumType, .set:
            return true
        case .integer, .decimal, .date, .timestamp, .datetime, .boolean, .blob, .json, .spatial, .array:
            return false
        }
    }

    /// Whether the column holds character data an engine compares with `LIKE` natively. A `.text`
    /// column is only what the classifier could not place elsewhere, so `uuid`, `inet` and every
    /// unknown type land there too, and their raw name is what separates them from `varchar`.
    static func isCharacterType(_ type: ColumnType?) -> Bool {
        guard case let .text(rawType)? = type else { return false }
        guard let rawType else { return true }
        let base = rawType.prefix { $0 != "(" }
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
        if characterBaseNames.contains(base) { return true }
        return base.contains("CHAR") || base.hasSuffix("TEXT")
    }

    private static let characterBaseNames: Set<String> = [
        "STRING", "FIXEDSTRING", "CLOB", "NCLOB", "NAME", "CITEXT"
    ]

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
