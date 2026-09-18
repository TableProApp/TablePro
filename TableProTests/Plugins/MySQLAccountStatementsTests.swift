//
//  MySQLAccountStatementsTests.swift
//  TableProTests
//
//  Banners measured through libmariadb's mysql_get_server_info against ten Docker servers.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("MySQL account statements")
struct MySQLAccountStatementsTests {
    private static let user = PluginPrincipalRef(name: "u", host: "%")

    private func statements(_ syntax: MySQLAccountSyntax) -> MySQLAccountStatements {
        MySQLAccountStatements(
            syntax: syntax,
            account: { "`\($0.name)`@`\($0.host ?? "%")`" },
            literal: { mysqlEscapeStringLiteral($0) }
        )
    }

    private func definition(password: String? = nil, limit: Int? = nil) -> PluginPrincipalDefinition {
        PluginPrincipalDefinition(ref: Self.user, password: password, connectionLimit: limit)
    }

    @Test("ALTER USER arrived in MySQL 5.7.6 and MariaDB 10.2.0")
    func syntaxFloors() {
        let legacyMySQL = ["5.5.62", "5.6.51", "5.7.5"]
        for banner in legacyMySQL {
            #expect(MySQLServerVersion.accountSyntax(banner: banner, flavor: .mysql) == .grantUsage)
        }
        for banner in ["5.7.6", "5.7.44", "8.4.11"] {
            #expect(MySQLServerVersion.accountSyntax(banner: banner, flavor: .mysql) == .alterUser)
        }
        let legacyMariaDB = ["5.5.64-MariaDB-1~trusty", "10.0.38-MariaDB-1~xenial", "10.1.48-MariaDB-1~bionic"]
        for banner in legacyMariaDB {
            #expect(MySQLServerVersion.accountSyntax(banner: banner, flavor: .mariadb) == .grantUsage)
        }
        let modernMariaDB = [
            "10.2.0-MariaDB",
            "10.2.44-MariaDB-1:10.2.44+maria~bionic",
            "10.6.28-MariaDB-ubu2204",
            "11.4.13-MariaDB-ubu2404"
        ]
        for banner in modernMariaDB {
            #expect(MySQLServerVersion.accountSyntax(banner: banner, flavor: .mariadb) == .alterUser)
        }
    }

    @Test("A banner that lies, or that cannot be read, keeps ALTER USER")
    func bannerIsIgnoredWhereItLies() {
        #expect(MySQLServerVersion.accountSyntax(
            banner: "5.6.25", flavor: .oceanbase(version: MySQLEngineVersion(major: 4, minor: 4, patch: 2))
        ) == .alterUser)
        #expect(MySQLServerVersion.accountSyntax(
            banner: "5.7.25-TiDB-v6.5.0", flavor: .tidb(version: MySQLEngineVersion(major: 6, minor: 5, patch: 0))
        ) == .alterUser)
        #expect(MySQLServerVersion.accountSyntax(banner: "8.0.90-v1.2.3-nightly", flavor: .databend) == .alterUser)
        #expect(MySQLServerVersion.accountSyntax(banner: nil, flavor: .mysql) == .alterUser)
        #expect(MySQLServerVersion.accountSyntax(banner: "unknown", flavor: .mariadb) == .alterUser)
    }

    @Test("A legacy create puts the account in first, then the limit")
    func legacyCreate() {
        #expect(statements(.grantUsage).create(definition(password: "pw", limit: 4)) == [
            "CREATE USER `u`@`%` IDENTIFIED BY 'pw'",
            "GRANT USAGE ON *.* TO `u`@`%` WITH MAX_USER_CONNECTIONS 4"
        ])
        #expect(statements(.grantUsage).create(definition(password: "pw")) == [
            "CREATE USER `u`@`%` IDENTIFIED BY 'pw'"
        ])
    }

    @Test("A modern create is one statement")
    func modernCreate() {
        #expect(statements(.alterUser).create(definition(password: "pw", limit: 4)) == [
            "CREATE USER `u`@`%` IDENTIFIED BY 'pw' WITH MAX_USER_CONNECTIONS 4"
        ])
        #expect(statements(.alterUser).create(definition(limit: 2)) == [
            "CREATE USER `u`@`%` WITH MAX_USER_CONNECTIONS 2"
        ])
        #expect(statements(.alterUser).create(definition()) == ["CREATE USER `u`@`%`"])
    }

    /// `SET PASSWORD FOR acct = PASSWORD('p')` is the other legacy spelling and is not used:
    /// measured on MariaDB 10.1.48 against a `unix_socket` account it answered `Query OK, 1
    /// warning` and left the old password working, and on a MySQL 5.6 `sha256_password` account it
    /// gave `ERROR 1827`. `GRANT USAGE ... IDENTIFIED BY` cleared the plugin in both.
    @Test("A password goes in as the form the server takes, escaped")
    func setPassword() {
        #expect(statements(.grantUsage).setPassword("it's \\x", for: Self.user) == [
            "GRANT USAGE ON *.* TO `u`@`%` IDENTIFIED BY 'it''s \\\\x'"
        ])
        #expect(statements(.alterUser).setPassword("it's \\x", for: Self.user) == [
            "ALTER USER `u`@`%` IDENTIFIED BY 'it''s \\\\x'"
        ])
    }

    @Test("A cleared limit goes in as zero, and an unchanged one emits nothing")
    func alterLimit() {
        let four = definition(limit: 4)
        let none = definition()
        let six = definition(limit: 6)
        #expect(statements(.alterUser).alter(old: four, new: none)
            == ["ALTER USER `u`@`%` WITH MAX_USER_CONNECTIONS 0"])
        #expect(statements(.grantUsage).alter(old: four, new: none)
            == ["GRANT USAGE ON *.* TO `u`@`%` WITH MAX_USER_CONNECTIONS 0"])
        #expect(statements(.alterUser).alter(old: none, new: six)
            == ["ALTER USER `u`@`%` WITH MAX_USER_CONNECTIONS 6"])
        #expect(statements(.grantUsage).alter(old: four, new: four).isEmpty)
    }

    @Test("A rename follows the limit change, in both grammars")
    func alterRename() {
        let old = definition(limit: 4)
        let renamed = PluginPrincipalDefinition(
            ref: PluginPrincipalRef(name: "v", host: "%"), connectionLimit: 6
        )
        #expect(statements(.alterUser).alter(old: old, new: renamed) == [
            "ALTER USER `u`@`%` WITH MAX_USER_CONNECTIONS 6",
            "RENAME USER `u`@`%` TO `v`@`%`"
        ])
        #expect(statements(.grantUsage).alter(old: old, new: renamed) == [
            "GRANT USAGE ON *.* TO `u`@`%` WITH MAX_USER_CONNECTIONS 6",
            "RENAME USER `u`@`%` TO `v`@`%`"
        ])
    }

    @Test("Neither grammar borrows a statement the other server removed")
    func grammarsDoNotMix() {
        let modern = statements(.alterUser)
        let legacy = statements(.grantUsage)
        let modernOutput = modern.create(definition(password: "p", limit: 1))
            + modern.setPassword("p", for: Self.user)
            + modern.alter(old: definition(limit: 1), new: definition(limit: 2))
        for statement in modernOutput {
            #expect(!statement.contains("GRANT USAGE"))
            #expect(!statement.contains("PASSWORD("))
        }
        let legacyOutput = legacy.create(definition(password: "p", limit: 1))
            + legacy.setPassword("p", for: Self.user)
            + legacy.alter(old: definition(limit: 1), new: definition(limit: 2))
        for statement in legacyOutput {
            #expect(!statement.contains("ALTER USER"))
            #expect(!statement.contains("SET PASSWORD"))
            #expect(!statement.contains("CREATE USER `u`@`%` IDENTIFIED BY 'p' WITH"))
        }
    }
}
