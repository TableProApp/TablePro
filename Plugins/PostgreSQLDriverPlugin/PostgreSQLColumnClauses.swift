//
//  PostgreSQLColumnClauses.swift
//  PostgreSQLDriverPlugin
//
//  What a column definition writes for its type, its default and its generation expression. Pure,
//  so the choice between the server's own spelling and the classified one is pinned by a test
//  without loading the driver.
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

    static func defaultExpression(for column: PluginColumnDefinition) -> String? {
        column.ddlDefault ?? column.defaultValue
    }

    static func generationExpression(for column: PluginColumnDefinition) -> String? {
        (column.ddlGenerationExpression ?? column.generationExpression)?.nilIfEmpty
    }

    private static let bigIntegerSpellings: Set<String> = ["BIGINT", "INT8"]
}
