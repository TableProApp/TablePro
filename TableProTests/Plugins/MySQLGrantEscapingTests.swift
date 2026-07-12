//
//  MySQLGrantEscapingTests.swift
//  TableProTests
//
//  In a MySQL GRANT the database-name position is a LIKE pattern, so `_` and `%`
//  must be escaped or a grant intended for one database silently matches others.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("MySQL GRANT pattern escaping")
struct MySQLGrantEscapingTests {
    @Test("Wildcard characters are escaped in the database position")
    func escapesWildcards() {
        #expect(MySQLGrantPatternEscaping.escapeDatabasePattern("prod_forums") == #"prod\_forums"#)
        #expect(MySQLGrantPatternEscaping.escapeDatabasePattern("100%off") == #"100\%off"#)
        #expect(MySQLGrantPatternEscaping.escapeDatabasePattern(#"back\slash"#) == #"back\\slash"#)
    }

    @Test("Names without wildcards are left alone")
    func leavesPlainNames() {
        #expect(MySQLGrantPatternEscaping.escapeDatabasePattern("analytics") == "analytics")
    }

    @Test(
        "Escaping round-trips",
        arguments: [
            "prod_forums",
            "100%off",
            #"back\slash"#,
            "analytics",
            "a_b%c",
            #"a\_b"#,
            #"\"#,
            "_",
            "%",
            ""
        ]
    )
    func roundTrips(name: String) {
        let escaped = MySQLGrantPatternEscaping.escapeDatabasePattern(name)
        #expect(MySQLGrantPatternEscaping.unescapeDatabasePattern(escaped) == name)
    }
}

@Suite("MySQL SHOW GRANTS parsing")
struct MySQLGrantParserTests {
    @Test("Server scope")
    func parsesServerScope() {
        let grant = MySQLGrantParser.parseGrant("GRANT SELECT, INSERT ON *.* TO `u`@`h`")
        #expect(grant?.scope == .server)
        #expect(grant?.privileges == ["SELECT", "INSERT"])
    }

    @Test("Escaped database name is unescaped back to its literal form")
    func parsesEscapedDatabaseScope() {
        let grant = MySQLGrantParser.parseGrant(#"GRANT SELECT ON `prod\_forums`.* TO `u`@`h`"#)
        #expect(grant?.scope == .database("prod_forums"))
    }

    @Test("Table scope")
    func parsesTableScope() {
        let grant = MySQLGrantParser.parseGrant("GRANT SELECT ON `shop`.`orders` TO `u`@`h`")
        #expect(grant?.scope == .table(database: "shop", schema: nil, table: "orders"))
    }

    @Test("WITH GRANT OPTION is detected")
    func parsesGrantOption() {
        let withOption = MySQLGrantParser.parseGrant("GRANT SELECT ON `db`.* TO `u`@`h` WITH GRANT OPTION")
        let withoutOption = MySQLGrantParser.parseGrant("GRANT SELECT ON `db`.* TO `u`@`h`")
        #expect(withOption?.isGrantable == true)
        #expect(withoutOption?.isGrantable == false)
    }

    @Test("Column-scoped privileges do not split on their inner comma")
    func parsesColumnScopedPrivileges() {
        let grant = MySQLGrantParser.parseGrant("GRANT SELECT (id, name), INSERT ON `db`.`t` TO `u`@`h`")
        #expect(grant?.privileges == ["SELECT", "INSERT"])
        #expect(grant?.isColumnScoped == true)
    }

    @Test("Multi-word and dynamic privileges survive")
    func parsesMultiWordPrivileges() {
        let multiWord = MySQLGrantParser.parseGrant(
            "GRANT CREATE TEMPORARY TABLES, REPLICATION SLAVE ON *.* TO `u`@`h`"
        )
        #expect(multiWord?.privileges == ["CREATE TEMPORARY TABLES", "REPLICATION SLAVE"])

        let dynamic = MySQLGrantParser.parseGrant("GRANT BACKUP_ADMIN ON *.* TO `u`@`h`")
        #expect(dynamic?.privileges == ["BACKUP_ADMIN"])
    }

    @Test("Role grants are not privilege grants")
    func separatesRoleGrants() {
        let line = "GRANT `dev`@`%` TO `alice`@`localhost`"
        #expect(MySQLGrantParser.parseGrant(line) == nil)
        #expect(MySQLGrantParser.parseRoleGrant(line) == ["dev"])
    }
}

@Suite("Privilege name sanitizer")
struct PluginPrivilegeNameTests {
    @Test("Rejects anything that is not a privilege keyword")
    func rejectsInjection() {
        #expect(PluginPrivilegeName.sanitized("SELECT; DROP DATABASE x; --") == nil)
        #expect(PluginPrivilegeName.sanitized("SEL`ECT") == nil)
        #expect(PluginPrivilegeName.sanitized("") == nil)
    }

    @Test("Accepts real privilege names")
    func acceptsPrivileges() {
        #expect(PluginPrivilegeName.sanitized("select") == "SELECT")
        #expect(PluginPrivilegeName.sanitized("BACKUP_ADMIN") == "BACKUP_ADMIN")
        #expect(PluginPrivilegeName.sanitized("CREATE TEMPORARY TABLES") == "CREATE TEMPORARY TABLES")
    }
}
