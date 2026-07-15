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
        grantBuilder(for: changeSet.principal).grantStatements(changeSet.grantsToAdd)
    }

    func generateRevokeSQL(changeSet: PluginPrincipalChangeSet) -> [String]? {
        grantBuilder(for: changeSet.principal).revokeStatements(changeSet.grantsToRemove)
    }

    private func grantBuilder(for principal: PluginPrincipalRef) -> PluginGrantSQLBuilder {
        PluginGrantSQLBuilder(
            grantee: grantAccount(principal),
            quoteIdentifier: { self.quoteIdentifier($0) },
            target: { self.grantTarget(for: $0) }
        )
    }
}
