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
        let base = baseName(of: rawType)
        if characterBaseNames.contains(base) { return true }
        return base.contains("CHAR") || base.hasSuffix("TEXT")
    }

    /// Whether `column = 'literal'` is a valid comparison for the column's own type. Large objects
    /// and XML have no equality operator on the engines that define them (Oracle ORA-00932, SQL
    /// Server error 402, PostgreSQL `operator does not exist: xml = unknown`), and neither does
    /// PostgreSQL's `json`.
    static func hasEqualityOperator(_ type: ColumnType) -> Bool {
        switch type {
        case .text(let rawType):
            guard let rawType else { return true }
            return !typesWithoutEquality.contains(baseName(of: rawType))
        case .integer, .decimal, .date, .timestamp, .datetime, .boolean, .enumType, .set:
            return true
        case .blob, .json, .spatial, .array:
            return false
        }
    }

    private static func baseName(of rawType: String) -> String {
        rawType.prefix { $0 != "(" }
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
    }

    private static let characterBaseNames: Set<String> = [
        "STRING", "FIXEDSTRING", "CLOB", "NCLOB", "NAME", "CITEXT"
    ]

    private static let typesWithoutEquality: Set<String> = [
        "CLOB", "NCLOB", "NTEXT", "LONG", "XML", "XMLTYPE"
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
