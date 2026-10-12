//
//  MySQLAccountStatements.swift
//  MySQLDriverPlugin
//
//  The account grammar one server takes. Pure, so TableProTests compiles it.
//

import Foundation
import TableProPluginKit

internal enum MySQLAccountSyntax: Equatable, Sendable {
    case alterUser
    case grantUsage
}

internal extension MySQLServerVersion {
    /// Which account grammar this server takes. `CREATE USER ... WITH MAX_USER_CONNECTIONS`,
    /// `ALTER USER ... WITH MAX_USER_CONNECTIONS` and `ALTER USER ... IDENTIFIED BY` all arrived in
    /// MySQL 5.7.6 and MariaDB 10.2.0; measured, MySQL 5.5.62 and 5.6.51 and MariaDB 5.5.64,
    /// 10.0.38 and 10.1.48 answer `ERROR 1064` to all three.
    ///
    /// TiDB and OceanBase ignore the banner, which lies about them: OceanBase handshakes as 5.7.25,
    /// or 5.6.25 through OBProxy.
    static func accountSyntax(banner: String?, flavor: MySQLServerFlavor) -> MySQLAccountSyntax {
        switch flavor {
        case .mysql:
            return isKnownBelow((5, 7, 6), banner: banner) ? .grantUsage : .alterUser
        case .mariadb:
            return isKnownBelow((10, 2, 0), banner: banner) ? .grantUsage : .alterUser
        case .tidb, .oceanbase, .databend:
            return .alterUser
        }
    }
}

/// `CREATE USER ... WITH MAX_USER_CONNECTIONS`, `ALTER USER ... WITH MAX_USER_CONNECTIONS` and
/// `ALTER USER ... IDENTIFIED BY` all arrived in MySQL 5.7.6 and MariaDB 10.2.0, and MySQL 8
/// removed every form that works below them, so no single spelling reaches both.
///
/// The legacy password goes in as `GRANT USAGE ON *.* TO acct IDENTIFIED BY 'p'` rather than
/// `SET PASSWORD FOR acct = PASSWORD('p')`, which fails silently for an account on an auth plugin:
/// measured on MariaDB 10.1.48 against a `unix_socket` account, `SET PASSWORD` answered `Query OK,
/// 1 warning` with `Note 1699 SET PASSWORD has no significance for users authenticating via
/// plugins`, left the plugin in place, and the new password then got `ERROR 1698`. The `GRANT`
/// cleared the plugin and the login worked, which is what 10.2's `ALTER USER` does too. It also
/// avoids the `ERROR 1827` a MySQL 5.6 `sha256_password` account gives `SET PASSWORD`. The cost is
/// that it needs `GRANT OPTION` as well as `UPDATE` on `mysql.*`, and that it re-creates an account
/// another admin dropped between the load and the apply.
internal struct MySQLAccountStatements {
    internal let syntax: MySQLAccountSyntax
    internal let account: (PluginPrincipalRef) -> String
    internal let literal: (String) -> String

    internal init(
        syntax: MySQLAccountSyntax,
        account: @escaping (PluginPrincipalRef) -> String,
        literal: @escaping (String) -> String
    ) {
        self.syntax = syntax
        self.account = account
        self.literal = literal
    }

    internal func create(_ definition: PluginPrincipalDefinition) -> [String] {
        let name = account(definition.ref)
        var statement = "CREATE USER \(name)"
        if let password = definition.password, !password.isEmpty {
            statement += " IDENTIFIED BY '\(literal(password))'"
        }
        guard let limit = definition.connectionLimit else { return [statement] }
        guard syntax == .alterUser else {
            /// `CREATE USER` first, because it is the statement that fails on a duplicate account:
            /// measured on MySQL 5.5.62, 5.6.51 and MariaDB 5.5.64 and 10.0.38, the `GRANT` on its
            /// own creates a passwordless account instead.
            return [statement, connectionLimit(limit, for: definition.ref)]
        }
        return [statement + " WITH MAX_USER_CONNECTIONS \(limit)"]
    }

    internal func alter(
        old: PluginPrincipalDefinition,
        new: PluginPrincipalDefinition
    ) -> [String] {
        var statements: [String] = []
        if old.connectionLimit != new.connectionLimit {
            statements.append(connectionLimit(new.connectionLimit ?? 0, for: old.ref))
        }
        if old.ref != new.ref {
            statements.append("RENAME USER \(account(old.ref)) TO \(account(new.ref))")
        }
        return statements
    }

    internal func setPassword(_ password: String, for principal: PluginPrincipalRef) -> [String] {
        let name = account(principal)
        guard syntax == .alterUser else {
            return ["GRANT USAGE ON *.* TO \(name) IDENTIFIED BY '\(literal(password))'"]
        }
        return ["ALTER USER \(name) IDENTIFIED BY '\(literal(password))'"]
    }

    private func connectionLimit(_ limit: Int, for principal: PluginPrincipalRef) -> String {
        let name = account(principal)
        guard syntax == .alterUser else {
            return "GRANT USAGE ON *.* TO \(name) WITH MAX_USER_CONNECTIONS \(limit)"
        }
        return "ALTER USER \(name) WITH MAX_USER_CONNECTIONS \(limit)"
    }
}
