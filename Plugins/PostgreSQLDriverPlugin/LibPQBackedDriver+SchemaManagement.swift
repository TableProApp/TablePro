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
            grants: try await fetchSchemaACL(name: name),
            currentRole: row[safe: 2]?.asText
        )
    }

    /// The grantee's kind comes from its id rather than its name: id zero is the all-users group,
    /// and a role can be named `public` without being it. The grantor comes back too, because
    /// `REVOKE` only removes what the executing role granted.
    private func fetchSchemaACL(name: String) async throws -> [PluginSchemaGrant] {
        guard supportsSchemaACLIntrospection else { return [] }
        let result = try await execute(query: PostgreSQLSchemaManagementQueries.grants(schema: name))
        return result.rows.compactMap { row -> PluginSchemaGrant? in
            guard let privilege = row[safe: 2]?.asText else { return nil }
            let granteeId = row[safe: 0]?.asText.flatMap(Int.init)
            let granteeName = row[safe: 1]?.asText ?? ""
            let grantee: PluginSchemaGrantee = (granteeId == 0 || granteeName.isEmpty)
                ? .publicGroup
                : .role(granteeName)
            return PluginSchemaGrant(
                grantee: grantee,
                privilege: privilege,
                isGrantable: PostgreSQLCatalogBoolean.isTrue(row[safe: 3]?.asText),
                grantor: row[safe: 4]?.asText?.nilIfBlank
            )
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        isEmpty ? nil : self
    }
}
