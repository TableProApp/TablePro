//
//  MySQLPluginDriver+PrincipalSQL.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension MySQLPluginDriver {
    func generateCreatePrincipalSQL(definition: PluginPrincipalDefinition) -> [String]? {
        let account = grantAccount(definition.ref)
        var statement = "CREATE USER \(account)"

        if let password = definition.password, !password.isEmpty {
            statement += " IDENTIFIED BY '\(escapeStringLiteral(password))'"
        }
        if let limit = definition.connectionLimit {
            statement += " WITH MAX_USER_CONNECTIONS \(limit)"
        }
        return [statement]
    }

    func generateAlterPrincipalSQL(
        old: PluginPrincipalDefinition,
        new: PluginPrincipalDefinition
    ) -> [String]? {
        var statements: [String] = []
        let account = grantAccount(old.ref)

        if old.connectionLimit != new.connectionLimit {
            statements.append("ALTER USER \(account) WITH MAX_USER_CONNECTIONS \(new.connectionLimit ?? 0)")
        }
        if old.ref != new.ref {
            statements.append("RENAME USER \(account) TO \(grantAccount(new.ref))")
        }
        return statements
    }

    func generateSetPasswordSQL(principal: PluginPrincipalRef, password: String) -> [String]? {
        let account = grantAccount(principal)
        return ["ALTER USER \(account) IDENTIFIED BY '\(escapeStringLiteral(password))'"]
    }

    func generateDropPrincipalSQL(
        principal: PluginPrincipalRef,
        options: PluginPrincipalDropOptions
    ) -> [String]? {
        ["DROP USER \(grantAccount(principal))"]
    }

    func generateGrantSQL(changeSet: PluginPrincipalChangeSet) -> [String]? {
        let account = grantAccount(changeSet.principal)
        return groupedByScope(changeSet.grantsToAdd).compactMap { scope, grants in
            guard let target = grantTarget(for: scope) else { return nil }
            let privileges = grants.compactMap { PluginPrivilegeName.sanitized($0.privilege) }
            guard !privileges.isEmpty else { return nil }
            let grantOption = grants.contains(where: \.isGrantable) ? " WITH GRANT OPTION" : ""
            return "GRANT \(privileges.joined(separator: ", ")) ON \(target) TO \(account)\(grantOption)"
        }
    }

    func generateRevokeSQL(changeSet: PluginPrincipalChangeSet) -> [String]? {
        let account = grantAccount(changeSet.principal)
        return groupedByScope(changeSet.grantsToRemove).compactMap { scope, grants in
            guard let target = grantTarget(for: scope) else { return nil }
            let privileges = grants.compactMap { PluginPrivilegeName.sanitized($0.privilege) }
            guard !privileges.isEmpty else { return nil }
            return "REVOKE \(privileges.joined(separator: ", ")) ON \(target) FROM \(account)"
        }
    }

    private func groupedByScope(
        _ grants: [PluginGrantInfo]
    ) -> [(scope: PluginPrivilegeScope, grants: [PluginGrantInfo])] {
        var order: [PluginPrivilegeScope] = []
        var buckets: [PluginPrivilegeScope: [PluginGrantInfo]] = [:]
        for grant in grants {
            if buckets[grant.scope] == nil {
                order.append(grant.scope)
            }
            buckets[grant.scope, default: []].append(grant)
        }
        return order.compactMap { scope in
            guard let grants = buckets[scope] else { return nil }
            return (scope, grants)
        }
    }
}
