import Foundation
import TableProCoreTypes
import TableProModels
import TableProPluginKit
import TableProSQLGrammar

// Unknown types fall to `.text`: `int_col = '5'` still matches everywhere, `text_col = 02134` finds the wrong row.
nonisolated public enum FilterColumnKind {
    // A nil engine keeps the table every engine shares.
    public static func kind(forTypeName typeName: String, databaseType: DatabaseType? = nil) -> PluginColumnKind {
        let base = typeName.lowercased().prefix { $0 != "(" }
        let words = base.split(whereSeparator: \.isWhitespace).filter { $0 != "unsigned" }
        // PostgreSQL's `bit varying` is a bit string, and `= 101` has no operator there.
        guard let first = words.first.map(String.init), !words.contains("varying") else { return .text }
        let kind: PluginColumnKind
        if integerNames.contains(first) {
            kind = .integer
        } else if decimalNames.contains(first) {
            kind = .decimal
        } else {
            return .text
        }
        return engineKind(kind, typeName: first, databaseType: databaseType)
    }

    public static func column(named name: String, in columns: [ColumnInfo]) -> ColumnInfo? {
        if let exact = columns.first(where: { $0.name == name }) { return exact }
        let folded = columns.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        return folded.count == 1 ? folded.first : nil
    }

    // A SQLite column with no affinity (typeless, any BLOB, ANY in a STRICT table) does not match a
    // stored 5 to `= '5'`: keep the untyped rule there.
    public static func kind(of column: ColumnInfo?, databaseType: DatabaseType? = nil) -> PluginColumnKind? {
        guard let column else { return nil }
        let typeName = column.typeName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !typeName.isEmpty, !typeName.contains("blob"), typeName != "any" else { return nil }
        return kind(forTypeName: typeName, databaseType: databaseType)
    }

    // An unread column counts as not character data, since a text cast is valid on every column.
    public static func isCharacterType(_ column: ColumnInfo?) -> Bool {
        guard let column else { return false }
        let base = column.typeName.lowercased().prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces)
        return base.contains("char") || base.hasSuffix("text") || characterNames.contains(base)
    }

    // SQLite keeps 5 and '5' apart in a column with no affinity, and the text the grid read cannot say which one it was.
    public static func comparesEitherStorageClass(_ column: ColumnInfo?, databaseType: DatabaseType?) -> Bool {
        databaseType == .sqlite && kind(of: column, databaseType: databaseType) == nil
    }

    // Character.isNumber takes digits of every script, and no engine parses those as a number.
    // An integer column takes a fraction bare too: PostgreSQL and SQL Server reject `int_col > '5.5'`.
    public static func isBareNumber(_ value: String, kind: PluginColumnKind?) -> Bool {
        guard value.unicodeScalars.allSatisfy(\.isASCII) else { return false }
        return kind != .text && PluginNumericLiteral.isValid(value)
    }

    // The literal that identifies a row by one key value. Off SQLite a column the caller could not read stays quoted,
    // which every typed column accepts except MySQL BIT. A REAL is matched one way only: the grid read SQLite's own
    // digits, which another spelling of the same value would match too, so a unique text key would read as ambiguous.
    public static func keyLiteral(_ value: String, column: ColumnInfo?, databaseType: DatabaseType) -> ComparisonLiteral {
        if comparesEitherStorageClass(column, databaseType: databaseType) {
            return SQLiteNumberText.isIntegerSpelling(value) ? .numberOrText(value) : .text(value)
        }
        guard let kind = kind(of: column, databaseType: databaseType) else { return .text(value) }
        return isBareNumber(value, kind: kind) ? .number(value) : .text(value)
    }

    // PostgreSQL resolves a quoted literal to the column's own type, so only an integer column needs a bare
    // number: `bit = 101` and `boolean = 1` have no operator, and a `real` never equals the numeric 0.1.
    // DuckDB runs `bit = 101` and finds no row; `bit = '101'` finds it.
    private static func engineKind(_ kind: PluginColumnKind, typeName: String, databaseType: DatabaseType?) -> PluginColumnKind {
        switch databaseType {
        case .postgresql?, .redshift?:
            return kind == .integer && !nonNumericIntegerNames.contains(typeName) ? .integer : .text
        case .duckdb?:
            return typeName == "bit" ? .text : kind
        default:
            return kind
        }
    }

    private static let characterNames: Set<String> = ["string", "clob", "nclob", "name", "citext"]

    private static let nonNumericIntegerNames: Set<String> = ["bit", "bool", "boolean"]

    private static let integerNames: Set<String> = [
        "int", "integer", "tinyint", "smallint", "mediumint", "bigint",
        "int1", "int2", "int3", "int4", "int8",
        "serial", "smallserial", "bigserial",
        "hugeint", "uhugeint", "utinyint", "usmallint", "uinteger", "ubigint",
        "bit", "bool", "boolean"
    ]

    private static let decimalNames: Set<String> = [
        "decimal", "numeric", "number", "real", "float", "double",
        "float4", "float8", "binary_float", "binary_double"
    ]
}

nonisolated public enum ComparisonLiteral: Equatable, Sendable {
    case number(String)
    case text(String)
    case numberOrText(String)
}
