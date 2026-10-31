//
//  StarRocksCatalog.swift
//  MySQLDriverPlugin
//
//  StarRocks puts catalogs above databases: `default_catalog` holds its own tables, and an external
//  catalog fronts Iceberg, Hive, Delta Lake or another engine. The connection browses catalogs where
//  MySQL browses databases, and a catalog's databases where a schema-switching engine browses schemas.
//

import Foundation
import TableProPluginKit

nonisolated internal enum StarRocksCatalog {
    static let defaultCatalog = "default_catalog"

    static let showCatalogs = "SHOW CATALOGS"

    static let showDatabases = "SHOW DATABASES"

    static func setCatalog(_ catalog: String) -> String {
        "SET CATALOG \(mysqlQuoteIdentifier(catalog))"
    }

    static func useDatabase(_ database: String) -> String {
        "USE \(mysqlQuoteIdentifier(database))"
    }

    /// What the Database field of a connection names.
    ///
    /// `catalog.database` is the form StarRocks itself takes in its handshake and in `USE`, and the one
    /// a connection imported from another client carries. Sent whole as one quoted name, the server
    /// reads it as a database called `catalog.database` and an Iceberg REST catalog refuses it as a
    /// malformed namespace. A name without a dot is ambiguous: a pooled metadata connection fills the
    /// field with the browsed catalog, while a connection typed by hand means a database in
    /// `default_catalog`, so it is settled against the server when the session opens.
    enum ConfiguredTarget: Equatable, Sendable {
        case serverDefault
        case qualified(catalog: String, database: String)
        case bareName(String)
    }

    static func target(fromConfiguredDatabase text: String) -> ConfiguredTarget {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .serverDefault }
        guard let dot = trimmed.firstIndex(of: ".") else { return .bareName(trimmed) }
        let catalog = String(trimmed[..<dot])
        let database = String(trimmed[trimmed.index(after: dot)...])
        guard !catalog.isEmpty else { return .bareName(database) }
        return .qualified(catalog: catalog, database: database)
    }

    static func names(from rows: [[PluginCellValue]]) -> [String] {
        rows.compactMap { $0[safe: 0]?.asText?.nilIfEmpty }
    }
}
