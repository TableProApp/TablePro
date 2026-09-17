//
//  PostgreSQLColumnClauses.swift
//  PostgreSQLDriverPlugin
//
//  What a column definition writes for its type, its collation, its default and its generation
//  expression. Pure, so the choice between the server's own spelling and the classified one is
//  pinned by a test without loading the driver.
//

import Foundation
import TableProPluginKit

enum PostgreSQLColumnClauses {
    /// `ddlSpelling` first, because it is the one spelling that names the type's schema and keeps its
    /// modifier: `dataType` says `geometry` for `public.geometry(Point,4326)` and `ENUM` for an enum,
    /// and PostgreSQL rejects both under a `search_path` that is only the target schema.
    ///
    /// The serial rewrite runs on whichever spelling was chosen, so a `bigint` read from the catalog
    /// becomes `BIGSERIAL` exactly as a `BIGINT` typed into the structure editor does.
    static func type(for column: PluginColumnDefinition) -> String {
        let declared = column.ddlSpelling ?? column.dataType
        guard column.autoIncrement else { return declared }
        return bigIntegerSpellings.contains(declared.uppercased()) ? "BIGSERIAL" : "SERIAL"
    }

    /// The same choice for `ALTER COLUMN ... TYPE`, which takes no serial pseudo-type: a serial column
    /// is an integer column with a sequence default, and PostgreSQL rejects `TYPE SERIAL`.
    static func alteredType(for column: PluginColumnDefinition) -> String {
        column.ddlSpelling ?? column.dataType
    }

    /// What follows `COLLATE`, or nil to write no clause.
    ///
    /// Only `ddlCollation`, never `collation`: that one is a display name with no schema, and
    /// PostgreSQL refuses both `COLLATE C` and a collation named outside its own schema. It is
    /// written while the column is still the type it was read as, where the server already took that
    /// collation, and after a retype only to one of the built-in string types, which take any
    /// collation. Anything else might not take one at all: `COLLATE` on an `integer`, a serial or an
    /// enum is refused, and a domain or an extension type is left to its own default.
    static func collation(for column: PluginColumnDefinition) -> String? {
        guard !column.autoIncrement, let collation = column.ddlCollation else { return nil }
        guard column.ddlSpelling != nil || isBuiltInStringType(column.dataType) else { return nil }
        return collation
    }

    /// The argument of `ALTER COLUMN ... TYPE`, or nil when neither the type nor the collation moved.
    ///
    /// The collation goes in every retype that keeps one, because `TYPE` without `COLLATE` resets it
    /// to the new type's default: measured on PostgreSQL 17.11, `varchar(10) COLLATE "C"` retyped to
    /// `varchar(20)` came back with the database default. A collation that changed on its own is a
    /// retype to the same type. It rebuilds the column's indexes, and like any retype it is refused
    /// on a column a view or a generated column reads.
    static func alterType(old: PluginColumnDefinition, new: PluginColumnDefinition) -> String? {
        let typeChanged = old.dataType.uppercased() != new.dataType.uppercased()
        guard typeChanged || old.ddlCollation != new.ddlCollation else { return nil }
        let type = alteredType(for: new)
        guard let collation = collation(for: new) else { return type }
        return "\(type) COLLATE \(collation)"
    }

    static func defaultExpression(for column: PluginColumnDefinition) -> String? {
        column.ddlDefault ?? column.defaultValue
    }

    static func generationExpression(for column: PluginColumnDefinition) -> String? {
        (column.ddlGenerationExpression ?? column.generationExpression)?.nilIfEmpty
    }

    private static let bigIntegerSpellings: Set<String> = ["BIGINT", "INT8"]

    /// Every spelling PostgreSQL's grammar gives `text`, `varchar` and `bpchar`, with any modifier and
    /// array bounds after it. Measured on PostgreSQL 17.11, each takes `COLLATE pg_catalog."C"`.
    private static func isBuiltInStringType(_ dataType: String) -> Bool {
        let base = dataType.prefix { $0 != "(" && $0 != "[" }
        let words = base.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return builtInStringTypes.contains(words)
    }

    private static let builtInStringTypes: Set<String> = [
        "TEXT", "VARCHAR", "BPCHAR",
        "CHARACTER", "CHARACTER VARYING", "CHAR", "CHAR VARYING",
        "NATIONAL CHARACTER", "NATIONAL CHARACTER VARYING", "NATIONAL CHAR", "NATIONAL CHAR VARYING",
        "NCHAR", "NCHAR VARYING"
    ]
}
