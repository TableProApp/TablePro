//
//  ColumnType.swift
//  TablePro
//
//  Column type metadata for type-aware formatting and display.
//  Driver-specific type mapping lives in each plugin; this enum is display-only.
//

import Foundation

/// Which editor an array's elements get.
///
/// A Bool could only say that an array has a per-element editor, never which one, and the two are
/// not the same control: a scalar element fits a one-line field, a JSON element is a document and
/// needs the JSON viewer.
enum ArrayElementEditor: Equatable, Sendable {
    case scalar
    case json
}

/// Represents the semantic type of a database column
enum ColumnType: Equatable, Sendable {
    case text(rawType: String?)
    case integer(rawType: String?)
    case decimal(rawType: String?)
    case date(rawType: String?)
    case timestamp(rawType: String?)
    case datetime(rawType: String?)
    case boolean(rawType: String?)
    case blob(rawType: String?)
    case json(rawType: String?)
    case enumType(rawType: String?, values: [String]?)
    case set(rawType: String?, values: [String]?)
    case spatial(rawType: String?)
    indirect case array(rawType: String?, element: ColumnType)

    /// Raw database type name (e.g., "LONGTEXT", "VARCHAR(255)", "CLOB")
    var rawType: String? {
        switch self {
        case .text(let raw), .integer(let raw), .decimal(let raw),
             .date(let raw), .timestamp(let raw), .datetime(let raw),
             .boolean(let raw), .blob(let raw), .json(let raw),
             .spatial(let raw), .array(let raw, _):
            return raw
        case .enumType(let raw, _), .set(let raw, _):
            return raw
        }
    }

    // MARK: - Display Properties

    /// Human-readable name for this column type
    var displayName: String {
        switch self {
        case .text: return "Text"
        case .integer: return "Integer"
        case .decimal: return "Decimal"
        case .date: return "Date"
        case .timestamp: return "Timestamp"
        case .datetime: return "DateTime"
        case .boolean: return "Boolean"
        case .blob: return "Binary"
        case .json: return "JSON"
        case .enumType: return "Enum"
        case .set: return "Set"
        case .spatial: return "Spatial"
        case .array(_, let element): return "\(element.displayName) Array"
        }
    }

    /// Whether this type represents a JSON value that should use JSON editor
    var isJsonType: Bool {
        switch self {
        case .json:
            return true
        default:
            return false
        }
    }

    /// Whether this type represents a date/time value that should be formatted
    var isDateType: Bool {
        switch self {
        case .date, .timestamp, .datetime:
            return true
        default:
            return false
        }
    }

    var isTimeOnly: Bool {
        guard isDateType, let raw = rawType?.uppercased() else { return false }
        let base = raw.prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
        return base == "TIME"
            || base == "TIMETZ"
            || base == "TIME WITHOUT TIME ZONE"
            || base == "TIME WITH TIME ZONE"
    }

    /// Whether this type represents long text that should use multi-line editor
    /// Checks for TEXT, LONGTEXT, MEDIUMTEXT, TINYTEXT, CLOB types
    var isLongText: Bool {
        guard let raw = rawType?.uppercased() else {
            return false
        }

        // MySQL long text types (exact match to avoid matching VARCHAR, etc.)
        if raw == "TEXT" || raw == "TINYTEXT" || raw == "MEDIUMTEXT" || raw == "LONGTEXT" {
            return true
        }

        // PostgreSQL/SQLite CLOB type, MSSQL NTEXT type
        if raw == "CLOB" || raw == "NTEXT" {
            return true
        }

        return false
    }

    /// Whether this type is a very large text type that should be excluded from browse queries.
    /// Only MEDIUMTEXT (16MB), LONGTEXT (4GB), and CLOB — not plain TEXT (65KB) or TINYTEXT (255B).
    var isVeryLongText: Bool {
        guard let raw = rawType?.uppercased() else { return false }
        return raw == "MEDIUMTEXT" || raw == "LONGTEXT" || raw == "CLOB"
    }

    /// Whether this type is an enum column
    var isEnumType: Bool {
        switch self {
        case .enumType:
            return true
        default:
            return false
        }
    }

    /// Whether this type is a SET column
    var isSetType: Bool {
        switch self {
        case .set:
            return true
        default:
            return false
        }
    }

    /// True from the result set alone, before the allowed values arrive on the metadata round trip.
    var isEnumOrSetType: Bool {
        isEnumType || isSetType
    }

    var isBooleanType: Bool {
        switch self {
        case .boolean: return true
        default: return false
        }
    }

    var isBlobType: Bool {
        switch self {
        case .blob: return true
        default: return false
        }
    }

    /// The element type of an array column, if this is one
    var arrayElement: ColumnType? {
        switch self {
        case .array(_, let element): return element
        default: return nil
        }
    }

    /// The editor this array's elements get, or nil where they cannot be edited one at a time.
    ///
    /// A JSON element is included because PostgreSQL's array quoting round-trips it exactly: the
    /// literal a `jsonb[]` cell carries parses to its elements and re-serializes byte for byte,
    /// SQL NULL and JSON null included. Binary, spatial and nested arrays stay out.
    var arrayElementEditor: ArrayElementEditor? {
        guard let element = arrayElement else { return nil }
        switch element {
        case .text, .integer, .decimal, .date, .timestamp, .datetime, .boolean, .enumType, .set:
            return .scalar
        case .json:
            return .json
        case .blob, .spatial, .array:
            return nil
        }
    }

    /// Whether this array's elements can be edited one at a time
    var supportsElementEditing: Bool { arrayElementEditor != nil }

    /// Compact lowercase badge label for sidebar
    var badgeLabel: String {
        switch self {
        case .boolean: return "bool"
        case .json: return "json"
        case .date, .timestamp, .datetime: return "date"
        case .enumType(let rawType, _):
            return rawType == "RedisType" ? "option" : "enum"
        case .set: return "set"
        case .integer(let rawType):
            return rawType == "RedisInt" ? "second" : "number"
        case .decimal: return "number"
        case .blob: return "binary"
        case .text(let rawType):
            return rawType == "RedisRaw" ? "raw" : "string"
        case .spatial: return "spatial"
        case .array(_, let element): return "\(element.badgeLabel)[]"
        }
    }

    /// The same type with the labels the catalog declared, reaching inside an array to its element.
    ///
    /// The classifier cannot know them: a column's labels arrive separately in
    /// `TableRows.columnEnumValues`. Injecting them on the scalar cases alone left an `ENUM[]`
    /// column's element editor with no vocabulary, so it offered free-form text where the grid
    /// offers the declared labels.
    func withAllowedValues(_ values: [String]) -> ColumnType {
        switch self {
        case .enumType(let rawType, _):
            return .enumType(rawType: rawType, values: values)
        case .set(let rawType, _):
            return .set(rawType: rawType, values: values)
        case .array(let rawType, let element):
            return .array(rawType: rawType, element: element.withAllowedValues(values))
        case .text, .integer, .decimal, .date, .timestamp, .datetime, .boolean, .blob, .json, .spatial:
            return self
        }
    }

    /// The allowed enum/set values, if known
    var enumValues: [String]? {
        switch self {
        case .enumType(_, let values), .set(_, let values):
            return values
        case .array(_, let element):
            return element.enumValues
        default:
            return nil
        }
    }
}
