//
//  ColumnType.swift
//  TablePro
//
//  Column type metadata for type-aware formatting and display.
//  Driver-specific type mapping lives in each plugin; this enum is display-only.
//

import Foundation

/// Represents the semantic type of a database column
enum ColumnType: Equatable {
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

    /// Raw database type name (e.g., "LONGTEXT", "VARCHAR(255)", "CLOB")
    var rawType: String? {
        switch self {
        case .text(let raw), .integer(let raw), .decimal(let raw),
             .date(let raw), .timestamp(let raw), .datetime(let raw),
             .boolean(let raw), .blob(let raw), .json(let raw),
             .spatial(let raw):
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
        }
    }

    /// The allowed enum/set values, if known
    var enumValues: [String]? {
        switch self {
        case .enumType(_, let values), .set(_, let values):
            return values
        default:
            return nil
        }
    }
}
