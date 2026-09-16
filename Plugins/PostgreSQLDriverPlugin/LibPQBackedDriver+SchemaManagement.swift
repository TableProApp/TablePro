//
//  LibPQBackedDriver+SchemaManagement.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension LibPQBackedDriver {
    /// `aclexplode` arrived in PostgreSQL 8.4 and Redshift forked before it, so reading a schema's
    /// ACL is the one part of schema management that is not shared. An engine that answers false
    /// reports the owner and the comment and leaves the grant list empty, which is what its
    /// `supportsSchemaPrivileges` capability already tells the UI to expect.
    var supportsSchemaACLIntrospection: Bool { true }

    func dropSchema(name: String) async throws {
        _ = try await execute(query: "DROP SCHEMA \(quoteIdentifier(name)) CASCADE")
    }

    func createSchemaStatement(name: String) -> String? {
        "CREATE SCHEMA IF NOT EXISTS \(quoteIdentifier(name))"
    }

    func createSchemaStatements(_ definition: PluginSchemaDefinition) -> [String]? {
        PostgreSQLSchemaStatementPlanner.create(definition)
    }

    func renameSchemaStatements(name: String, to newName: String) -> [String]? {
        [PostgreSQLSchemaManagementQueries.rename(name: name, to: newName)]
    }

    func alterSchemaStatements(
        from current: PluginSchemaDetails,
        to target: PluginSchemaDefinition
    ) -> [String]? {
        PostgreSQLSchemaStatementPlanner.alter(from: current, to: target)
    }

    func fetchSchemaDetails(name: String) async throws -> PluginSchemaDetails? {
        let header = try await execute(query: PostgreSQLSchemaManagementQueries.ownerAndComment(schema: name))
        guard let row = header.rows.first else { return nil }
        return PluginSchemaDetails(
            name: name,
            owner: row[safe: 0]?.asText,
            comment: row[safe: 1]?.asText,
            grants: try await fetchSchemaACL(name: name)
        )
    }

    private func fetchSchemaACL(name: String) async throws -> [PluginSchemaGrant] {
        guard supportsSchemaACLIntrospection else { return [] }
        let result = try await execute(query: PostgreSQLSchemaManagementQueries.grants(schema: name))
        return result.rows.compactMap { row -> PluginSchemaGrant? in
            guard let grantee = row[safe: 0]?.asText,
                  let privilege = row[safe: 1]?.asText else { return nil }
            return PluginSchemaGrant(
                grantee: grantee,
                privilege: privilege,
                isGrantable: PostgreSQLCatalogBoolean.isTrue(row[safe: 2]?.asText)
            )
        }
    }
}
