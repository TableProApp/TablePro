//
//  PostgreSQLPluginDriver+TriggerEditing.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal extension PostgreSQLPluginDriver {
    var triggerEditUsesReplace: Bool { versionedCapabilities.hasCreateOrReplaceTrigger }

    var supportsTransactionalDDL: Bool { true }

    func qualifiedTable(_ table: String, schema: String?) -> String {
        let resolved = schema ?? core.currentSchema
        return "\(quoteIdentifier(resolved)).\(quoteIdentifier(table))"
    }

    func createTriggerTemplate(table: String, schema: String?) -> String? {
        PostgreSQLVersionedStatements.triggerTemplate(
            qualifiedTable: qualifiedTable(table, schema: schema),
            qualifiedFunction: qualifiedTable("trigger_function", schema: schema),
            capabilities: versionedCapabilities
        )
    }

    func fetchTriggerDefinition(name: String, table: String, schema: String?) async throws -> String? {
        let resolvedSchema = schema ?? core.currentSchema
        let query = """
            SELECT pg_get_functiondef(t.tgfoid), pg_get_triggerdef(t.oid)
            FROM pg_catalog.pg_trigger t
            JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE t.tgname = \(PostgreSQLObjectQueries.quoteLiteral(name))
                AND c.relname = \(PostgreSQLObjectQueries.quoteLiteral(table))
                AND n.nspname = \(PostgreSQLObjectQueries.quoteLiteral(resolvedSchema))
                AND NOT t.tgisinternal
            LIMIT 1
            """
        let result = try await execute(query: query)
        guard let row = result.rows.first, row.count >= 2,
              let functionDef = row[0].asText,
              let triggerDef = row[1].asText else { return nil }
        return PostgreSQLVersionedStatements.editableTriggerDefinition(
            functionDefinition: functionDef,
            triggerDefinition: triggerDef,
            dropStatement: generateDropTriggerSQL(name: name, table: table, schema: schema),
            capabilities: versionedCapabilities
        )
    }

    func generateDropTriggerSQL(name: String, table: String, schema: String?) -> String? {
        "DROP TRIGGER IF EXISTS \(quoteIdentifier(name)) ON \(qualifiedTable(table, schema: schema))"
    }
}
