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
            statements.append(
                "ALTER USER \(account) WITH MAX_USER_CONNECTIONS \(new.connectionLimit ?? 0)"
            )
        }
        if old.ref != new.ref {
            statements.append("RENAME USER \(account) TO \(grantAccount(new.ref))")
        }
        return statements
    }

    func generateSetPasswordSQL(principal: PluginPrincipalRef, password: String) -> [String]? {
        ["ALTER USER \(grantAccount(principal)) IDENTIFIED BY '\(escapeStringLiteral(password))'"]
    }

    func generateDropPrincipalSQL(
        principal: PluginPrincipalRef,
        options: PluginPrincipalDropOptions
    ) -> [String]? {
        ["DROP USER \(grantAccount(principal))"]
    }

    func generateGrantSQL(changeSet: PluginPrincipalChangeSet) -> [String]? {
        PluginGrantGrouping.group(changeSet.grantsToAdd).compactMap { group in
            guard let target = grantTarget(for: group.scope),
                  let clause = privilegeClause(for: group) else { return nil }
            let grantOption = group.isGrantable ? " WITH GRANT OPTION" : ""
            return "GRANT \(clause) ON \(target) TO \(grantAccount(changeSet.principal))\(grantOption)"
        }
    }

    func generateRevokeSQL(changeSet: PluginPrincipalChangeSet) -> [String]? {
        PluginGrantGrouping.group(changeSet.grantsToRemove).compactMap { group in
            guard let target = grantTarget(for: group.scope),
                  let clause = privilegeClause(for: group) else { return nil }
            return "REVOKE \(clause) ON \(target) FROM \(grantAccount(changeSet.principal))"
        }
    }

    private func privilegeClause(for group: PluginGrantGroup) -> String? {
        var parts = group.privileges.compactMap(PluginPrivilegeName.sanitized)

        parts += group.columnPrivileges.compactMap { entry -> String? in
            guard let privilege = PluginPrivilegeName.sanitized(entry.privilege),
                  !entry.columns.isEmpty else { return nil }
            let columns = entry.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
            return "\(privilege) (\(columns))"
        }

        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
