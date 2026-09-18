//
//  ForeignKeyLookupColumn.swift
//  TablePro
//

import Foundation

/// A column of the table a foreign key points at, as the value picker needs it: the name to quote
/// and the type that decides which predicates can be built against it.
struct ForeignKeyLookupColumn: Equatable, Sendable, Identifiable {
    let name: String
    let type: ColumnType

    var id: String { name }

    /// Whether `LIKE` is defined for this column on a strict engine.
    ///
    /// `ColumnType` cannot answer it. `ColumnTypeClassifier` files `UUID`, `UNIQUEIDENTIFIER` and
    /// `SQL_VARIANT` under `.text` by name, and every type it does not recognise under `.text` by
    /// fallback, while PostgreSQL has no `~~` for `uuid`, for an enum or for an array. So the
    /// question is asked of the raw type name and answered closed: a name that is not a known
    /// character type carries no pattern predicate, which costs a search rather than an error on
    /// every search.
    var supportsPatternMatch: Bool {
        guard case .text = type, let base = Self.baseTypeName(of: type.rawType) else { return false }
        return Self.characterTypeNames.contains(base)
    }

    /// A UUID takes no `LIKE`, but it does take equality against a literal the engine can parse.
    var isUuid: Bool {
        guard let base = Self.baseTypeName(of: type.rawType) else { return false }
        return Self.uuidTypeNames.contains(base)
    }

    private static let characterTypeNames: Set<String> = [
        "TEXT", "VARCHAR", "CHAR", "NVARCHAR", "NCHAR", "NTEXT",
        "VARCHAR2", "NVARCHAR2", "CLOB", "NCLOB",
        "STRING", "FIXEDSTRING", "CHARACTER", "CHARACTER VARYING",
        "BPCHAR", "CITEXT",
        "TINYTEXT", "MEDIUMTEXT", "LONGTEXT",
    ]

    private static let uuidTypeNames: Set<String> = ["UUID", "UNIQUEIDENTIFIER"]

    /// The same shape `ColumnTypeClassifier` reads: the wrappers off, the parameters off, uppercased.
    static func baseTypeName(of rawType: String?) -> String? {
        guard let rawType else { return nil }
        var value = rawType.trimmingCharacters(in: .whitespaces)
        for prefix in ["Nullable(", "LowCardinality("] where value.hasPrefix(prefix) && value.hasSuffix(")") {
            value = String(value.dropFirst(prefix.count).dropLast())
            return baseTypeName(of: value)
        }
        if let paren = value.firstIndex(of: "(") {
            value = String(value[value.startIndex ..< paren])
        }
        let base = value.trimmingCharacters(in: .whitespaces).uppercased()
        return base.isEmpty ? nil : base
    }
}
