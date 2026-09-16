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
        let grantee: PluginSchemaGrantee
        let privilege: String
    }

    private struct GrantState: Hashable {
        let isGrantable: Bool
        let grantor: String?
    }

    static func create(_ definition: PluginSchemaDefinition) -> [String] {
        let name = definition.name
        var statements = [PostgreSQLSchemaManagementQueries.create(name: name, owner: definition.owner)]
        if let comment = definition.comment, !comment.isEmpty {
            statements.append(PostgreSQLSchemaManagementQueries.comment(name: name, to: comment))
        }
        statements += grantStatements(schema: name, adding: normalized(definition.grants))
        return statements
    }

    static func alter(from current: PluginSchemaDetails, to target: PluginSchemaDefinition) -> [String] {
        var statements: [String] = []

        /// The rename goes first and every later statement names the new schema, because the old
        /// name stops resolving the moment it runs.
        if target.name != current.name {
            statements.append(PostgreSQLSchemaManagementQueries.rename(name: current.name, to: target.name))
        }
        let name = target.name

        if let owner = target.owner, !owner.isEmpty, owner != current.owner {
            statements.append(PostgreSQLSchemaManagementQueries.changeOwner(name: name, to: owner))
        }

        if target.comment != current.comment {
            statements.append(PostgreSQLSchemaManagementQueries.comment(name: name, to: target.comment))
        }

        statements += grantDiff(
            schema: name,
            before: normalized(current.grants),
            after: normalized(target.grants),
            currentRole: current.currentRole
        )
        return statements
    }

    private static func normalized(_ grants: [PluginSchemaGrant]) -> [GrantKey: GrantState] {
        var result: [GrantKey: GrantState] = [:]
        for grant in grants {
            guard let privilege = PluginPrivilegeName.sanitized(grant.privilege) else { continue }
            let key = GrantKey(grantee: grant.grantee, privilege: privilege)
            /// Several grantors can hold the same grantee and privilege. The grantable bit is
            /// unioned, and the grantor kept only while they agree: a privilege held through two
            /// grantors is not one this role can revoke on its own.
            guard let existing = result[key] else {
                result[key] = GrantState(isGrantable: grant.isGrantable, grantor: grant.grantor)
                continue
            }
            result[key] = GrantState(
                isGrantable: existing.isGrantable || grant.isGrantable,
                grantor: existing.grantor == grant.grantor ? existing.grantor : nil
            )
        }
        return result
    }

    private static func grantDiff(
        schema: String,
        before: [GrantKey: GrantState],
        after: [GrantKey: GrantState],
        currentRole: String?
    ) -> [String] {
        var statements = grantStatements(
            schema: schema,
            adding: after.filter { before[$0.key]?.isGrantable != $0.value.isGrantable }
        )

        /// A `REVOKE` removes only what the executing role granted, so one is emitted only where
        /// this role is the sole grantor. Anything else is left alone rather than run and reported
        /// as done: the statement would succeed, change nothing, and the access would remain.
        let removable = before.filter { key, state in
            after[key] == nil && canRevoke(state, as: currentRole)
        }
        statements += grouped(removable.mapValues { _ in false }).map { group in
            "REVOKE \(group.privileges) ON \(target(schema))"
                + " FROM \(PostgreSQLSchemaManagementQueries.render(group.grantee))"
        }

        let downgraded = before.filter { key, state in
            state.isGrantable
                && after[key]?.isGrantable == false
                && canRevoke(state, as: currentRole)
        }
        statements += grouped(downgraded.mapValues { _ in false }).map { group in
            "REVOKE GRANT OPTION FOR \(group.privileges) ON \(target(schema))"
                + " FROM \(PostgreSQLSchemaManagementQueries.render(group.grantee))"
        }
        return statements
    }

    /// Whether the connected role can actually take this grant away. An unknown grantor, or two
    /// grantors disagreeing, both mean no.
    static func canRevoke(grantor: String?, as currentRole: String?) -> Bool {
        guard let grantor, let currentRole, !grantor.isEmpty, !currentRole.isEmpty else { return false }
        return grantor == currentRole
    }

    private static func canRevoke(_ state: GrantState, as currentRole: String?) -> Bool {
        canRevoke(grantor: state.grantor, as: currentRole)
    }

    private static func target(_ schema: String) -> String {
        "SCHEMA \(PostgreSQLObjectQueries.quoteIdentifier(schema))"
    }

    private static func grantStatements(schema: String, adding: [GrantKey: GrantState]) -> [String] {
        grouped(adding.mapValues(\.isGrantable)).map { group in
            let option = group.isGrantable ? " WITH GRANT OPTION" : ""
            return "GRANT \(group.privileges) ON \(target(schema))"
                + " TO \(PostgreSQLSchemaManagementQueries.render(group.grantee))\(option)"
        }
    }

    private struct Group {
        let grantee: PluginSchemaGrantee
        let isGrantable: Bool
        let privileges: String
    }

    private static func grouped(_ entries: [GrantKey: Bool]) -> [Group] {
        var buckets: [PluginSchemaGrantee: [Bool: [String]]] = [:]
        for (key, isGrantable) in entries {
            buckets[key.grantee, default: [:]][isGrantable, default: []].append(key.privilege)
        }
        return buckets.keys
            .sorted { $0.displayName < $1.displayName }
            .flatMap { grantee -> [Group] in
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
