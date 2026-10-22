import Foundation
@testable import TableProMSSQLCore
import Testing

struct MSSQLPrincipalStatementsTests {
    private let directory = MSSQLPrincipalDirectory(
        database: "Sales",
        logins: [
            .init(name: "sa", isDisabled: false, user: "dbo"),
            .init(name: "app", isDisabled: false, user: "app"),
            .init(name: "CORP\\bob", isDisabled: false, user: "bob"),
            .init(name: "fresh", isDisabled: false, user: nil)
        ],
        serverRoles: ["sysadmin", "auditors"],
        databasePrincipals: [
            .init(name: "db_datareader", isRole: true, hasConnect: false),
            .init(name: "readers", isRole: true, hasConnect: false),
            .init(name: "guest", isRole: false, hasConnect: false)
        ],
        serverMemberships: [.init(member: "app", role: "auditors")],
        databaseMemberships: [
            .init(member: "app", role: "readers"),
            .init(member: "bob", role: "readers")
        ]
    )

    private var statements: MSSQLPrincipalStatements { MSSQLPrincipalStatements(directory: directory) }

    private let ensureFresh = "IF NOT EXISTS (SELECT 1 FROM sys.database_principals "
        + "WHERE name = N'fresh' AND sid = SUSER_SID(N'fresh')) CREATE USER [fresh] FOR LOGIN [fresh]"

    private func inSales(_ statement: String) -> String {
        MSSQLPrincipalStatements.inDatabase("Sales", statement)
    }

    // MARK: - Create

    @Test func testCreateUserMakesALoginAndItsUser() {
        let sql = statements.create(name: "carol", password: "pa'ss", canLogin: true, memberOf: [])

        #expect(sql == [
            "CREATE LOGIN [carol] WITH PASSWORD = N'pa''ss'",
            "EXEC [Sales].sys.sp_executesql N'CREATE USER [carol] FOR LOGIN [carol]'"
        ])
    }

    @Test func testCreateUserWithoutPasswordIsRefused() {
        #expect(statements.create(name: "carol", password: nil, canLogin: true, memberOf: []) == nil)
        #expect(statements.create(name: "carol", password: "", canLogin: true, memberOf: []) == nil)
    }

    @Test func testCreateRoleIsADatabaseRole() {
        let sql = statements.create(name: "writers", password: nil, canLogin: false, memberOf: ["db_datareader"])

        #expect(sql == [
            inSales("CREATE ROLE [writers]"),
            inSales("ALTER ROLE [db_datareader] ADD MEMBER [writers]")
        ])
    }

    @Test func testCreatedUserJoinsServerAndDatabaseRoles() {
        let sql = statements.create(name: "carol", password: "x", canLogin: true, memberOf: ["sysadmin", "readers"])

        #expect(sql?.suffix(2) == [
            inSales("ALTER ROLE [readers] ADD MEMBER [carol]"),
            "ALTER SERVER ROLE [sysadmin] ADD MEMBER [carol]"
        ])
    }

    @Test func testDatabaseRoleCannotJoinAServerRole() {
        #expect(statements.create(name: "writers", password: nil, canLogin: false, memberOf: ["sysadmin"]) == nil)
    }

    // MARK: - Alter

    @Test func testCanLogInTogglesTheLogin() {
        #expect(statements.alter(name: "app", oldCanLogin: true, newCanLogin: false, oldMemberOf: [], newMemberOf: [])
            == ["ALTER LOGIN [app] DISABLE"])
        #expect(statements.alter(name: "app", oldCanLogin: false, newCanLogin: true, oldMemberOf: [], newMemberOf: [])
            == ["ALTER LOGIN [app] ENABLE"])
    }

    @Test func testCanLogInOnADatabaseUserIsTheConnectPermission() {
        #expect(statements.alter(name: "guest", oldCanLogin: false, newCanLogin: true, oldMemberOf: [], newMemberOf: [])
            == [inSales("GRANT CONNECT TO [guest]")])
        #expect(statements.alter(name: "guest", oldCanLogin: true, newCanLogin: false, oldMemberOf: [], newMemberOf: [])
            == [inSales("REVOKE CONNECT FROM [guest]")])
    }

    @Test func testCanLogInOnARoleIsRefused() {
        #expect(statements.alter(
            name: "readers", oldCanLogin: false, newCanLogin: true, oldMemberOf: [], newMemberOf: []
        ) == nil)
    }

    @Test func testDatabaseRoleMembershipUsesTheMappedUser() {
        let sql = statements.alter(
            name: "sa", oldCanLogin: true, newCanLogin: true, oldMemberOf: [], newMemberOf: ["readers"]
        )

        #expect(sql == [inSales("ALTER ROLE [readers] ADD MEMBER [dbo]")])
    }

    @Test func testServerRoleMembershipUsesTheLogin() {
        let sql = statements.alter(
            name: "app", oldCanLogin: true, newCanLogin: true, oldMemberOf: ["auditors"], newMemberOf: ["sysadmin"]
        )

        #expect(sql == [
            "ALTER SERVER ROLE [auditors] DROP MEMBER [app]",
            "ALTER SERVER ROLE [sysadmin] ADD MEMBER [app]"
        ])
    }

    @Test func testLoginWithoutAUserGetsOneBeforeJoiningADatabaseRole() {
        let sql = statements.alter(
            name: "fresh", oldCanLogin: true, newCanLogin: true, oldMemberOf: [],
            newMemberOf: ["db_datareader", "readers"]
        )

        #expect(sql == [
            inSales(ensureFresh),
            inSales("ALTER ROLE [db_datareader] ADD MEMBER [fresh]"),
            inSales("ALTER ROLE [readers] ADD MEMBER [fresh]")
        ])
    }

    // MARK: - Password and drop

    @Test func testPasswordGoesToTheLoginOrTheContainedUser() {
        #expect(statements.setPassword(name: "app", password: "n'ew") == ["ALTER LOGIN [app] WITH PASSWORD = N'n''ew'"])
        #expect(statements.setPassword(name: "guest", password: "x")
            == [inSales("ALTER USER [guest] WITH PASSWORD = N'x'")])
        #expect(statements.setPassword(name: "readers", password: "x") == nil)
    }

    @Test func testDropLoginDropsItsUserFirst() {
        #expect(statements.drop(name: "CORP\\bob") == [inSales("DROP USER [bob]"), "DROP LOGIN [CORP\\bob]"])
        #expect(statements.drop(name: "fresh") == ["DROP LOGIN [fresh]"])
    }

    @Test func testDropRoleEmptiesItFirst() {
        #expect(statements.drop(name: "readers") == [
            inSales("IF DATABASE_PRINCIPAL_ID(N'app') IS NOT NULL ALTER ROLE [readers] DROP MEMBER [app]"),
            inSales("IF DATABASE_PRINCIPAL_ID(N'bob') IS NOT NULL ALTER ROLE [readers] DROP MEMBER [bob]"),
            inSales("DROP ROLE [readers]")
        ])
        #expect(statements.drop(name: "auditors") == [
            "IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'app') "
                + "ALTER SERVER ROLE [auditors] DROP MEMBER [app]",
            "DROP SERVER ROLE [auditors]"
        ])
        #expect(statements.drop(name: "guest") == [inSales("DROP USER [guest]")])
    }

    @Test func testDropOfAnUnknownNameIsRefused() {
        #expect(statements.drop(name: "nobody") == nil)
        #expect(MSSQLPrincipalStatements(directory: nil).drop(name: "app") == nil)
    }

    // MARK: - Permissions

    @Test func testServerPermissionsRunInTheSystemDatabase() {
        let sql = statements.grantStatements(
            [MSSQLGrant(permission: "VIEW SERVER STATE", securable: .server)],
            to: "app"
        )

        #expect(sql == ["EXEC [master].sys.sp_executesql N'GRANT VIEW SERVER STATE TO [app]'"])
    }

    @Test func testServerPermissionForADatabasePrincipalIsRefused() {
        #expect(statements.grantStatements([MSSQLGrant(permission: "SHUTDOWN", securable: .server)], to: "readers") == nil)
    }

    @Test func testDatabasePermissionForAServerRoleIsRefused() {
        #expect(statements.grantStatements([MSSQLGrant(permission: "SELECT", securable: .database)], to: "sysadmin") == nil)
    }

    @Test func testPermissionsAreGroupedPerSecurable() {
        let sql = statements.grantStatements(
            [
                MSSQLGrant(permission: "CREATE TABLE", securable: .database),
                MSSQLGrant(permission: "SELECT", securable: .schema("dbo")),
                MSSQLGrant(permission: "INSERT", securable: .schema("dbo")),
                MSSQLGrant(permission: "SELECT", securable: .object(schema: "dbo", name: "Orders"), column: "id"),
                MSSQLGrant(permission: "SELECT", securable: .object(schema: "dbo", name: "Orders"), column: "total"),
                MSSQLGrant(permission: "DELETE", securable: .object(schema: "dbo", name: "Orders"))
            ],
            to: "sa"
        )

        #expect(sql == [
            inSales("GRANT CREATE TABLE TO [dbo]"),
            inSales("GRANT SELECT, INSERT ON SCHEMA::[dbo] TO [dbo]"),
            inSales("GRANT DELETE, SELECT ([id], [total]) ON OBJECT::[dbo].[Orders] TO [dbo]")
        ])
    }

    @Test func testDatabasePermissionForALoginWithoutAUserCreatesTheUserOnce() {
        let sql = statements.grantStatements(
            [
                MSSQLGrant(permission: "CONNECT", securable: .database),
                MSSQLGrant(permission: "SELECT", securable: .schema("dbo"))
            ],
            to: "fresh"
        )

        #expect(sql == [
            inSales(ensureFresh),
            inSales("GRANT CONNECT TO [fresh]"),
            inSales("GRANT SELECT ON SCHEMA::[dbo] TO [fresh]")
        ])
    }

    @Test func testRevokingAGrantableGrantCascades() {
        let sql = statements.revokeStatements(
            [
                MSSQLGrant(permission: "SELECT", securable: .object(schema: "dbo", name: "T"), withGrantOption: true),
                MSSQLGrant(permission: "UPDATE", securable: .object(schema: "dbo", name: "T"))
            ],
            from: "app"
        )

        #expect(sql == [
            inSales("REVOKE SELECT ON OBJECT::[dbo].[T] FROM [app] CASCADE"),
            inSales("REVOKE UPDATE ON OBJECT::[dbo].[T] FROM [app]")
        ])
    }

    @Test func testGrantOptionIsKept() {
        let sql = statements.grantStatements(
            [MSSQLGrant(permission: "SELECT", securable: .schema("dbo"), withGrantOption: true)],
            to: "readers"
        )

        #expect(sql == [inSales("GRANT SELECT ON SCHEMA::[dbo] TO [readers] WITH GRANT OPTION")])
    }

    @Test func testIdentifiersAndPermissionsAreEscaped() {
        let sql = statements.grantStatements(
            [
                MSSQLGrant(permission: "SELECT; DROP TABLE x", securable: .database),
                MSSQLGrant(permission: "select", securable: .object(schema: "d]bo", name: "a]\u{301}"))
            ],
            to: "we]ird"
        )

        #expect(sql == [inSales("GRANT SELECT ON OBJECT::[d]]bo].[a]]\u{301}] TO [we]]ird]")])
    }

    @Test func testColumnPermissionOutsideAnObjectIsRefused() {
        #expect(statements.grantStatements(
            [MSSQLGrant(permission: "SELECT", securable: .schema("dbo"), column: "id")],
            to: "app"
        ) == nil)
    }

    // The tab keeps describing the database it was read from after the session switches, so its statements name it.
    @Test func testDatabaseStatementsNameTheDatabaseTheListWasReadFrom() {
        #expect(inSales("GRANT SELECT TO [x]") == "EXEC [Sales].sys.sp_executesql N'GRANT SELECT TO [x]'")
        #expect(MSSQLPrincipalStatements.inDatabase("we]ird", "SELECT 'a'")
            == "EXEC [we]]ird].sys.sp_executesql N'SELECT ''a'''")
        #expect(MSSQLPrincipalStatements(directory: nil).grantStatements(
            [MSSQLGrant(permission: "SELECT", securable: .schema("dbo"))],
            to: "app"
        ) == ["GRANT SELECT ON SCHEMA::[dbo] TO [app]"])
    }

    @Test func testServerGrantTextIsQuotedForSpExecutesql() {
        let sql = statements.grantStatements(
            [MSSQLGrant(permission: "CONNECT SQL", securable: .server)],
            to: "o'brien"
        )

        #expect(sql == ["EXEC [master].sys.sp_executesql N'GRANT CONNECT SQL TO [o''brien]'"])
    }
}
