//
//  ColumnTypeCategory.swift
//  TablePro
//

import Foundation

/// The broad kind of value a column holds, read from its `ColumnType`, so every engine's spelling of a
/// type lands in the same few groups.
enum ColumnTypeCategory: CaseIterable, Sendable {
    case text
    case number
    case dateTime
    case boolean
    case binary
    case document
    case spatial
    case other

    init(_ type: ColumnType) {
        switch type {
        case .text(let rawType):
            self = Self.nonTextCategories[ColumnType.baseTypeName(rawType)] ?? .text
        case .integer, .decimal:
            self = .number
        case .date, .timestamp, .datetime:
            self = .dateTime
        case .boolean:
            self = .boolean
        case .blob:
            self = .binary
        // An array holds structured values like a JSON document, and PostgreSQL prints it in braces.
        case .json, .array:
            self = .document
        case .spatial:
            self = .spatial
        case .enumType, .set, .vector:
            self = .other
        }
    }

    /// Types the classifier files under text, since the grid edits them as text, whose values are not free text.
    private static let nonTextCategories: [String: ColumnTypeCategory] = [
        "YEAR": .dateTime,
        "INTERVAL": .dateTime,
        "XML": .document,
        "HSTORE": .document,
    ]
}
