import Foundation
@testable import TableProMSSQLCore
import Testing

struct MSSQLPrincipalQueriesTests {
    @Test func testGranteeNamesAreUnicodeLiterals() {
        #expect(MSSQLPrincipalQueries.serverPermissions(grantee: "o'brien").contains("g.name = N'o''brien'"))
        #expect(MSSQLPrincipalQueries.databasePermissions(grantee: "日本", database: "Sales").contains("g.name = N'日本'"))
        #expect(MSSQLPrincipalQueries.columns(schema: "d'bo", object: "T", database: "Sales").contains("s.name = N'd''bo'"))
    }

    // The tab keeps the database it was loaded on, so its reads name it rather than follow the session.
    @Test func testDatabaseViewsAreReadThroughTheLoadedDatabase() {
        let queries = [
            MSSQLPrincipalQueries.logins(database: "Sa]les"),
            MSSQLPrincipalQueries.databasePrincipals(database: "Sa]les"),
            MSSQLPrincipalQueries.databaseRoleMembers(database: "Sa]les"),
            MSSQLPrincipalQueries.databasePermissions(grantee: "x", database: "Sa]les"),
            MSSQLPrincipalQueries.schemas(database: "Sa]les"),
            MSSQLPrincipalQueries.objects(schema: "dbo", database: "Sa]les"),
            MSSQLPrincipalQueries.columns(schema: "dbo", object: "T", database: "Sa]les"),
            MSSQLPrincipalQueries.searchObjects(matching: "x", limit: 5, database: "Sa]les")
        ]
        for sql in queries {
            #expect(sql.contains("[Sa]]les].sys."))
            #expect(!sql.contains(" sys.database_"))
            #expect(!sql.contains(" sys.schemas"))
            #expect(!sql.contains(" sys.objects"))
        }
    }

    @Test func testSearchEscapesLikeWildcards() {
        let sql = MSSQLPrincipalQueries.searchObjects(matching: "a_[b]%", limit: 0, database: "Sales")

        #expect(sql.contains("TOP (1)"))
        #expect(sql.contains(#"LIKE N'%a\_\[b]\%%' ESCAPE '\'"#))
    }

    @Test func testParseLogins() {
        let logins = MSSQLPrincipalQueries.parseLogins([
            ["sa", "0", "dbo"],
            ["off", "1", nil],
            [nil, "0", nil]
        ])

        #expect(logins == [
            .init(name: "sa", isDisabled: false, user: "dbo"),
            .init(name: "off", isDisabled: true, user: nil)
        ])
    }

    @Test func testParseDatabasePrincipalsReadsTheTypeCode() {
        let rows = MSSQLPrincipalQueries.parseDatabasePrincipals([
            ["readers", "R ", "0"],
            ["guest", "S ", "1"]
        ])

        #expect(rows == [
            .init(name: "readers", isRole: true, hasConnect: false),
            .init(name: "guest", isRole: false, hasConnect: true)
        ])
    }

    @Test func testParseDatabasePermissionsMapsEachClass() {
        let grants = MSSQLPrincipalQueries.parseDatabasePermissions([
            ["0", "CONNECT", "G", nil, nil, nil],
            ["3", "SELECT", "W", "dbo", nil, nil],
            ["1", "UPDATE", "G", "dbo", "Orders", nil],
            ["1", "SELECT", "G", "dbo", "Orders", "total"],
            ["1", "SELECT", "G", nil, nil, nil],
            ["4", "IMPERSONATE", "G", nil, nil, nil]
        ])

        #expect(grants == [
            MSSQLGrant(permission: "CONNECT", securable: .database),
            MSSQLGrant(permission: "SELECT", securable: .schema("dbo"), withGrantOption: true),
            MSSQLGrant(permission: "UPDATE", securable: .object(schema: "dbo", name: "Orders")),
            MSSQLGrant(permission: "SELECT", securable: .object(schema: "dbo", name: "Orders"), column: "total")
        ])
    }

    @Test func testParseServerPermissions() {
        let grants = MSSQLPrincipalQueries.parseServerPermissions([["VIEW SERVER STATE", "W"], ["CONNECT SQL", "G"]])

        #expect(grants == [
            MSSQLGrant(permission: "VIEW SERVER STATE", securable: .server, withGrantOption: true),
            MSSQLGrant(permission: "CONNECT SQL", securable: .server)
        ])
    }

    @Test func testCatalogSplitsByClassAndLeavesOutModulePermissions() {
        let catalog = MSSQLPermissionCatalog(rows: [
            ("SERVER", "VIEW SERVER STATE"),
            ("DATABASE", "CREATE TABLE"),
            ("DATABASE", "SELECT"),
            ("SCHEMA", "ALTER"),
            ("OBJECT", "VIEW DEFINITION"),
            ("OBJECT", "DELETE"),
            ("OBJECT", "SELECT"),
            ("OBJECT", "EXECUTE"),
            ("OBJECT", "RECEIVE"),
            ("OBJECT", "bad;name")
        ])

        #expect(catalog.server == ["VIEW SERVER STATE"])
        #expect(catalog.database == ["SELECT", "CREATE TABLE"])
        #expect(catalog.schema == ["ALTER"])
        #expect(catalog.object == ["SELECT", "DELETE", "VIEW DEFINITION"])
    }

    @Test func testCatalogCategories() {
        #expect(MSSQLPermissionCatalog.category(of: "SELECT") == .data)
        #expect(MSSQLPermissionCatalog.category(of: "CREATE TABLE") == .structure)
        #expect(MSSQLPermissionCatalog.category(of: "ALTER ANY SCHEMA") == .structure)
        #expect(MSSQLPermissionCatalog.category(of: "VIEW SERVER STATE") == .administration)
    }
}
