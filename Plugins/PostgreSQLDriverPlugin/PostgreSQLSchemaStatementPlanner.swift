//
//  PostgreSQLSchemaStatementPlanner.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

/// Turns a schema's intended state into the statements that reach it.
///
/// Pure, so the text a sheet previews is the text a test pins and the text the server runs. The
/// diff is per grantee and per privilege: a grantee the user never touched produces neither a
/// GRANT nor a REVOKE, which is the whole point of reading the current state first.
enum PostgreSQLSchemaStatementPlanner {
    private struct GrantKey: Hashable {
        let grantee: String
        let privilege: String
    }

    static func create(_ definition: PluginSchemaDefinition) -> [String] {
        let name = definition.name
        var statements = [PostgreSQLSchemaManagementQueries.create(name: name, owner: definition.owner)]
        if let comment = definition.comment, !comment.isEmpty {
            statements.append(PostgreSQLSchemaManagementQueries.comment(name: name, to: comment))
        }
        statements += grantStatements(
            schema: name,
            adding: normalized(definition.grants),
            removing: [:]
        )
        return statements
    }

    static func alter(from current: PluginSchemaDetails, to target: PluginSchemaDefinition) -> [String] {
        var statements: [String] = []

        /// The rename goes first and every later statement names the new schema, because the old
        /// name stops resolving the moment it runs.
        let renamed = target.name != current.name
        if renamed {
            statements.append(PostgreSQLSchemaManagementQueries.rename(name: current.name, to: target.name))
        }
        let name = target.name

        if let owner = target.owner, !owner.isEmpty, owner != current.owner {
            statements.append(PostgreSQLSchemaManagementQueries.changeOwner(name: name, to: owner))
        }

        if target.comment != current.comment {
            statements.append(PostgreSQLSchemaManagementQueries.comment(name: name, to: target.comment))
        }

        let before = normalized(current.grants)
        let after = normalized(target.grants)
        statements += grantStatements(
            schema: name,
            adding: after.filter { before[$0.key] != $0.value },
            removing: before.filter { after[$0.key] == nil }
        )
        statements += revokeGrantOptionStatements(schema: name, before: before, after: after)

        return statements
    }

    private static func normalized(_ grants: [PluginSchemaGrant]) -> [GrantKey: Bool] {
        var result: [GrantKey: Bool] = [:]
        for grant in grants {
            guard let privilege = PluginPrivilegeName.sanitized(grant.privilege) else { continue }
            let key = GrantKey(grantee: grant.grantee, privilege: privilege)
            result[key] = (result[key] ?? false) || grant.isGrantable
        }
        return result
    }

    private static func grantStatements(
        schema: String,
        adding: [GrantKey: Bool],
        removing: [GrantKey: Bool]
    ) -> [String] {
        let target = "SCHEMA \(PostgreSQLObjectQueries.quoteIdentifier(schema))"
        var statements = grouped(adding).map { group in
            let option = group.isGrantable ? " WITH GRANT OPTION" : ""
            return "GRANT \(group.privileges) ON \(target)"
                + " TO \(PostgreSQLSchemaManagementQueries.quoteGrantee(group.grantee))\(option)"
        }
        statements += grouped(removing).map { group in
            "REVOKE \(group.privileges) ON \(target)"
                + " FROM \(PostgreSQLSchemaManagementQueries.quoteGrantee(group.grantee))"
        }
        return statements
    }

    /// Dropping the grant option alone keeps the privilege, so it is its own statement rather than
    /// a revoke followed by a re-grant: `REVOKE ... FROM` would take the privilege away with it.
    private static func revokeGrantOptionStatements(
        schema: String,
        before: [GrantKey: Bool],
        after: [GrantKey: Bool]
    ) -> [String] {
        let downgraded = before.filter { key, wasGrantable in
            wasGrantable && after[key] == false
        }
        let target = "SCHEMA \(PostgreSQLObjectQueries.quoteIdentifier(schema))"
        return grouped(downgraded).map { group in
            "REVOKE GRANT OPTION FOR \(group.privileges) ON \(target)"
                + " FROM \(PostgreSQLSchemaManagementQueries.quoteGrantee(group.grantee))"
        }
    }

    private struct Group {
        let grantee: String
        let isGrantable: Bool
        let privileges: String
    }

    private static func grouped(_ entries: [GrantKey: Bool]) -> [Group] {
        var buckets: [String: [Bool: [String]]] = [:]
        for (key, isGrantable) in entries {
            buckets[key.grantee, default: [:]][isGrantable, default: []].append(key.privilege)
        }
        return buckets.keys.sorted().flatMap { grantee -> [Group] in
            guard let byOption = buckets[grantee] else { return [] }
            return byOption.keys.sorted { !$0 && $1 }.compactMap { isGrantable in
                guard let privileges = byOption[isGrantable], !privileges.isEmpty else { return nil }
                return Group(
                    grantee: grantee,
                    isGrantable: isGrantable,
                    privileges: privileges.sorted().joined(separator: ", ")
                )
            }
        }
    }
}
