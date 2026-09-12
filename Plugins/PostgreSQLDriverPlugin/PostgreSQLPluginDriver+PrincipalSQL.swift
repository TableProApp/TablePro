//
//  PostgreSQLPluginDriver+PrincipalSQL.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension PostgreSQLPluginDriver {
    func generateCreatePrincipalSQL(definition: PluginPrincipalDefinition) -> [String]? {
        let role = quoteIdentifier(definition.ref.name)
        var options = [definition.canLogin ? "LOGIN" : "NOLOGIN"]
        options.append(contentsOf: attributeKeywords(definition.attributes))

        if let password = definition.password, !password.isEmpty {
            options.append("PASSWORD \(PostgreSQLObjectQueries.quoteLiteral(password))")
        }
        if let limit = definition.connectionLimit {
            options.append("CONNECTION LIMIT \(limit)")
        }

        var statements = ["CREATE ROLE \(role) WITH \(options.joined(separator: " "))"]
        statements.append(contentsOf: definition.memberOf.map {
            "GRANT \(quoteIdentifier($0)) TO \(role)"
        })
        if let comment = definition.comment, !comment.isEmpty {
            statements.append("COMMENT ON ROLE \(role) IS \(PostgreSQLRelationSQL.commentValue(comment))")
        }
        return statements
    }

    func generateAlterPrincipalSQL(
        old: PluginPrincipalDefinition,
        new: PluginPrincipalDefinition
    ) -> [String]? {
        var statements: [String] = []
        let role = quoteIdentifier(old.ref.name)

        var options: [String] = []
        if old.canLogin != new.canLogin {
            options.append(new.canLogin ? "LOGIN" : "NOLOGIN")
        }
        options.append(contentsOf: changedAttributeKeywords(old: old.attributes, new: new.attributes))
        if old.connectionLimit != new.connectionLimit {
            options.append("CONNECTION LIMIT \(new.connectionLimit ?? -1)")
        }
        if !options.isEmpty {
            statements.append("ALTER ROLE \(role) WITH \(options.joined(separator: " "))")
        }

        statements.append(contentsOf: membershipStatements(old: old, new: new, role: role))

        if old.comment != new.comment {
            statements.append("COMMENT ON ROLE \(role) IS \(PostgreSQLRelationSQL.commentValue(new.comment))")
        }
        if old.ref.name != new.ref.name {
            statements.append("ALTER ROLE \(role) RENAME TO \(quoteIdentifier(new.ref.name))")
        }
        return statements
    }

    func generateSetPasswordSQL(principal: PluginPrincipalRef, password: String) -> [String]? {
        let role = quoteIdentifier(principal.name)
        return ["ALTER ROLE \(role) WITH PASSWORD \(PostgreSQLObjectQueries.quoteLiteral(password))"]
    }

    func generateDropPrincipalSQL(
        principal: PluginPrincipalRef,
        options: PluginPrincipalDropOptions
    ) -> [String]? {
        let role = quoteIdentifier(principal.name)
        var statements: [String] = []

        if let reassignTarget = options.reassignOwnedTo {
            statements.append("REASSIGN OWNED BY \(role) TO \(quoteIdentifier(reassignTarget.name))")
            statements.append("DROP OWNED BY \(role)")
        } else if options.dropOwned {
            statements.append("DROP OWNED BY \(role)")
        }

        statements.append("DROP ROLE \(role)")
        return statements
    }

    func generateGrantSQL(changeSet: PluginPrincipalChangeSet) -> [String]? {
        grantBuilder(for: changeSet.principal).grantStatements(changeSet.grantsToAdd)
    }

    func generateRevokeSQL(changeSet: PluginPrincipalChangeSet) -> [String]? {
        grantBuilder(for: changeSet.principal).revokeStatements(changeSet.grantsToRemove)
    }

    private func grantBuilder(for principal: PluginPrincipalRef) -> PluginGrantSQLBuilder {
        PluginGrantSQLBuilder(
            grantee: quoteIdentifier(principal.name),
            quoteIdentifier: { self.quoteIdentifier($0) },
            target: { self.grantTarget(for: $0) }
        )
    }

    private func grantTarget(for scope: PluginPrivilegeScope) -> String? {
        switch scope {
        case .server:
            nil
        case let .database(name):
            "DATABASE \(quoteIdentifier(name))"
        case let .schema(_, schema):
            "SCHEMA \(quoteIdentifier(schema))"
        case let .table(_, schema, table), let .column(_, schema, table, _):
            if let schema {
                "TABLE \(quoteIdentifier(schema)).\(quoteIdentifier(table))"
            } else {
                "TABLE \(quoteIdentifier(table))"
            }
        @unknown default:
            nil
        }
    }

    private var supportedRoleAttributes: Set<PostgreSQLRoleAttribute> {
        PostgreSQLVersionedStatements.roleAttributes(capabilities: versionedCapabilities)
    }

    private func attributeKeywords(_ attributes: [PluginPrincipalAttribute]) -> [String] {
        let supported = supportedRoleAttributes
        return attributes.compactMap { attribute in
            guard let known = PostgreSQLRoleAttribute(rawValue: attribute.key), supported.contains(known) else {
                return nil
            }
            return known.keyword(isEnabled: attribute.isEnabled)
        }
    }

    private func changedAttributeKeywords(
        old: [PluginPrincipalAttribute],
        new: [PluginPrincipalAttribute]
    ) -> [String] {
        let oldByKey = Dictionary(uniqueKeysWithValues: old.map { ($0.key, $0.isEnabled) })
        let supported = supportedRoleAttributes
        return new.compactMap { attribute in
            guard let known = PostgreSQLRoleAttribute(rawValue: attribute.key), supported.contains(known) else {
                return nil
            }
            guard oldByKey[attribute.key] != attribute.isEnabled else { return nil }
            return known.keyword(isEnabled: attribute.isEnabled)
        }
    }

    private func membershipStatements(
        old: PluginPrincipalDefinition,
        new: PluginPrincipalDefinition,
        role: String
    ) -> [String] {
        let oldRoles = Set(old.memberOf)
        let newRoles = Set(new.memberOf)
        let granted = newRoles.subtracting(oldRoles).sorted()
        let revoked = oldRoles.subtracting(newRoles).sorted()

        return revoked.map { "REVOKE \(quoteIdentifier($0)) FROM \(role)" }
            + granted.map { "GRANT \(quoteIdentifier($0)) TO \(role)" }
    }
}
