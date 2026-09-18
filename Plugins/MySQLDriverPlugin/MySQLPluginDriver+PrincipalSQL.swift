//
//  MySQLPluginDriver+PrincipalSQL.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

extension MySQLPluginDriver {
    func generateCreatePrincipalSQL(definition: PluginPrincipalDefinition) -> [String]? {
        accountStatements.create(definition)
    }

    func generateAlterPrincipalSQL(
        old: PluginPrincipalDefinition,
        new: PluginPrincipalDefinition
    ) -> [String]? {
        accountStatements.alter(old: old, new: new)
    }

    func generateSetPasswordSQL(principal: PluginPrincipalRef, password: String) -> [String]? {
        accountStatements.setPassword(password, for: principal)
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

    private var accountStatements: MySQLAccountStatements {
        let identity = serverIdentity
        return MySQLAccountStatements(
            syntax: MySQLServerVersion.accountSyntax(banner: identity.banner, flavor: identity.flavor),
            account: { self.grantAccount($0) },
            literal: { self.escapeStringLiteral($0) }
        )
    }

    private func grantBuilder(for principal: PluginPrincipalRef) -> PluginGrantSQLBuilder {
        PluginGrantSQLBuilder(
            grantee: grantAccount(principal),
            quoteIdentifier: { self.quoteIdentifier($0) },
            target: { self.grantTarget(for: $0) }
        )
    }
}
