//
//  DuckDBPositionParser.swift
//  DuckDBDriverPlugin
//
//  Reads the catalog and schema a connection is sitting on out of DuckDB's own settings.
//  Extracted so it can be tested without a database handle.
//

import Foundation

enum DuckDBPositionParser {
    struct Position: Equatable {
        let catalog: String?
        let schema: String?
    }

    /// `USE` writes where it landed into `search_path` as `catalog.schema`, and the `schema`
    /// setting carries the schema on its own. Both are plain settings, so they answer without
    /// the `core_functions` extension that `current_database()` needs.
    ///
    /// The catalog here is whatever the caller typed: DuckDB resolves a catalog name
    /// case-insensitively but echoes the spelling back, so this value still has to be matched
    /// against `duckdb_databases()` before anything filters on it.
    static func parse(settings: [String: String]) -> Position {
        let firstEntry = settings["search_path"]?
            .split(separator: ",").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""

        guard let separator = firstEntry.firstIndex(of: ".") else {
            return Position(catalog: nil, schema: settings["schema"]?.nilIfEmptyPosition)
        }

        let catalog = String(firstEntry[firstEntry.startIndex..<separator])
        let schema = String(firstEntry[firstEntry.index(after: separator)...])
        return Position(
            catalog: catalog.nilIfEmptyPosition,
            schema: schema.nilIfEmptyPosition ?? settings["schema"]?.nilIfEmptyPosition
        )
    }
}

private extension String {
    var nilIfEmptyPosition: String? { isEmpty ? nil : self }
}
