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
    ///
    /// A column that declares no type at all is the one open answer, and it is not a gap in the
    /// list. Only a dynamically typed engine reports one: `create table t(a, b)` is legal SQLite
    /// and `PRAGMA table_xinfo` gives back a zero-length type for it, measured on 3.54.0, while
    /// every strict engine always names a type. `LIKE` is defined on every column there, measured
    /// on the same build, so an undeclared column takes a predicate and can be a label. Reading it
    /// as unknown instead left a hand-written SQLite database with no label anywhere and no way to
    /// search one.
    var supportsPatternMatch: Bool {
        guard case .text = type else { return false }
        guard let base = Self.baseTypeName(of: type.rawType) else { return declaresNoType }
        return Self.characterTypeNames.contains(base)
    }

    /// True when the engine answered with a type and that type was empty, which is how SQLite
    /// reports a column declared without one.
    ///
    /// A missing `rawType` is deliberately not this. That is the app having no type information at
    /// all, which several of its own conversions produce, and reading it as "the engine declared
    /// nothing" would hand a pattern predicate to a column nobody has typed.
    var declaresNoType: Bool {
        guard let rawType = type.rawType else { return false }
        return rawType.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The declared type as the reader sees it beside the column's name, or nothing when the
    /// engine declares none: SQLite accepts `create table t(a, b)`, and an empty string reads as a
    /// missing word rather than as a column with no type.
    var displayTypeName: String? {
        guard let rawType = type.rawType, !rawType.isEmpty else { return nil }
        return rawType
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
