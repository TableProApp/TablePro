//
//  PostgreSQLExtensionQueries.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProPostgreSQLCore

nonisolated enum PostgreSQLExtensions {
    static let kindId = "extension"

    static var kind: PluginServerObjectKind {
        PluginServerObjectKind(
            id: kindId,
            displayName: String(localized: "Extension"),
            pluralDisplayName: String(localized: "Extensions"),
            iconName: "puzzlepiece.extension",
            scope: .database
        )
    }

    static func isDeclared(capabilities: PostgreSQLCapabilities) -> Bool {
        capabilities.hasExtensionsCatalog
    }
}

// Every column a 9.1 server has; the default version reads control files on disk, so only one object asks for it.
nonisolated enum PostgreSQLExtensionQueries {
    private static let projection = """
        SELECT e.oid::pg_catalog.text, e.extname, n.nspname, e.extversion, e.extrelocatable,
               pg_catalog.pg_get_userbyid(e.extowner),
               pg_catalog.obj_description(e.oid, 'pg_extension')
        FROM pg_catalog.pg_extension e
        JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace
        """

    static let list = projection + "\nORDER BY e.extname"

    static func one(oid: UInt32) -> String {
        projection + "\nWHERE e.oid = \(oid)"
    }

    static func defaultVersion(name: String) -> String {
        """
        SELECT default_version FROM pg_catalog.pg_available_extensions
        WHERE name = \(PostgreSQLObjectQueries.quoteLiteral(name))
        """
    }

    // pg_dump's own form: it names the schema and intentionally leaves the version out.
    static func definition(name: String, schema: String, comment: String?) -> String {
        var text = "CREATE EXTENSION IF NOT EXISTS \(PostgreSQLObjectQueries.quoteIdentifier(name)) "
            + "WITH SCHEMA \(PostgreSQLObjectQueries.quoteIdentifier(schema));"
        if let comment, !comment.isEmpty {
            text += "\n\nCOMMENT ON EXTENSION \(PostgreSQLObjectQueries.quoteIdentifier(name)) "
                + "IS \(PostgreSQLObjectQueries.quoteLiteral(comment));"
        }
        return text
    }

    static func object(from row: [PluginCellValue], defaultVersion: String? = nil) -> PluginServerObjectInfo? {
        guard let oid = text(row, 0), UInt32(oid) != nil, let name = text(row, 1) else { return nil }
        let schema = text(row, 2)
        let version = text(row, 3)
        var attributes: [PluginObjectAttribute] = []
        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            attributes.append(PluginObjectAttribute(label: label, value: value))
        }
        add(String(localized: "Version"), version)
        add(String(localized: "Default Version"), defaultVersion)
        add(String(localized: "Schema"), schema)
        add(String(localized: "Owner"), text(row, 5))
        add(String(localized: "Relocatable"), text(row, 4).map { isTrue($0) ? String(localized: "Yes") : String(localized: "No") })
        add(String(localized: "Comment"), text(row, 6))
        return PluginServerObjectInfo(
            kindId: PostgreSQLExtensions.kindId,
            name: name,
            schema: schema,
            identity: oid,
            detail: version,
            definition: schema.map { definition(name: name, schema: $0, comment: text(row, 6)) },
            attributes: attributes
        )
    }

    // A boolean cell arrives as `true`/`false` once decoded, and as `t`/`f` from a text read.
    private static func isTrue(_ value: String) -> Bool {
        value == "true" || value == "t"
    }

    private static func text(_ row: [PluginCellValue], _ index: Int) -> String? {
        guard let value = row[safe: index]?.asText, !value.isEmpty else { return nil }
        return value
    }
}
