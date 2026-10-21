import Foundation
@testable import TableProOracleCore
import Testing

struct OraclePrincipalStatementsTests {
    private let statements = OraclePrincipalStatements(roles: ["APP_READ", "CONNECT"])

    @Test func testCreateUserWithPasswordAndRoles() {
        let sql = statements.create(name: "SCOTT", password: "tiger", canLogin: true, memberOf: ["RESOURCE", "CONNECT"])

        #expect(sql == [
            "CREATE USER \"SCOTT\" IDENTIFIED BY \"tiger\"",
            "GRANT \"CONNECT\" TO \"SCOTT\"",
            "GRANT \"RESOURCE\" TO \"SCOTT\""
        ])
    }

    @Test func testCreateUserNeedsAPasswordWithoutDoubleQuotes() {
        #expect(statements.create(name: "SCOTT", password: nil, canLogin: true, memberOf: []) == nil)
        #expect(statements.create(name: "SCOTT", password: "a\"b", canLogin: true, memberOf: []) == nil)
        #expect(statements.create(name: "SCOTT", password: "a\"\u{301}b", canLogin: true, memberOf: []) == nil)
        #expect(statements.setPassword(name: "SCOTT", password: "a\"\u{301}b") == nil)
    }

    @Test func testCreateRole() {
        #expect(statements.create(name: "APP_WRITE", password: nil, canLogin: false, memberOf: ["APP_READ"]) == [
            "CREATE ROLE \"APP_WRITE\"",
            "GRANT \"APP_READ\" TO \"APP_WRITE\""
        ])
    }

    @Test func testCanLogInLocksAndUnlocksTheAccount() {
        #expect(statements.alter(name: "SCOTT", oldCanLogin: true, newCanLogin: false, oldMemberOf: [], newMemberOf: [])
            == ["ALTER USER \"SCOTT\" ACCOUNT LOCK"])
        #expect(statements.alter(name: "SCOTT", oldCanLogin: false, newCanLogin: true, oldMemberOf: [], newMemberOf: [])
            == ["ALTER USER \"SCOTT\" ACCOUNT UNLOCK"])
        #expect(statements.alter(
            name: "APP_READ", oldCanLogin: false, newCanLogin: true, oldMemberOf: [], newMemberOf: []
        ) == nil)
    }

    @Test func testMembershipChanges() {
        let sql = statements.alter(
            name: "SCOTT", oldCanLogin: true, newCanLogin: true,
            oldMemberOf: ["CONNECT"], newMemberOf: ["APP_READ"]
        )

        #expect(sql == ["REVOKE \"CONNECT\" FROM \"SCOTT\"", "GRANT \"APP_READ\" TO \"SCOTT\""])
    }

    @Test func testPasswordAndDropFollowTheKind() {
        #expect(statements.setPassword(name: "SCOTT", password: "x") == ["ALTER USER \"SCOTT\" IDENTIFIED BY \"x\""])
        #expect(statements.setPassword(name: "APP_READ", password: "x") == nil)
        #expect(statements.drop(name: "SCOTT") == ["DROP USER \"SCOTT\""])
        #expect(statements.drop(name: "APP_READ") == ["DROP ROLE \"APP_READ\""])
    }

    @Test func testSystemPrivilegesUseAdminOption() {
        let sql = statements.grantStatements(
            [
                OracleGrant(privilege: "CREATE SESSION", securable: .system),
                OracleGrant(privilege: "create table", securable: .system),
                OracleGrant(privilege: "SELECT ANY TABLE", securable: .system, isGrantable: true)
            ],
            to: "SCOTT"
        )

        #expect(sql == [
            "GRANT CREATE SESSION, CREATE TABLE TO \"SCOTT\"",
            "GRANT SELECT ANY TABLE TO \"SCOTT\" WITH ADMIN OPTION"
        ])
    }

    @Test func testObjectAndColumnPrivileges() {
        let table = OracleSecurable.object(owner: "HR", name: "EMPLOYEES")
        let sql = statements.grantStatements(
            [
                OracleGrant(privilege: "SELECT", securable: table),
                OracleGrant(privilege: "UPDATE", securable: table, column: "SALARY"),
                OracleGrant(privilege: "UPDATE", securable: table, column: "BONUS"),
                OracleGrant(privilege: "DELETE", securable: table, isGrantable: true)
            ],
            to: "APP_READ"
        )

        #expect(sql == [
            "GRANT SELECT, UPDATE (\"SALARY\", \"BONUS\") ON \"HR\".\"EMPLOYEES\" TO \"APP_READ\"",
            "GRANT DELETE ON \"HR\".\"EMPLOYEES\" TO \"APP_READ\" WITH GRANT OPTION"
        ])
    }

    @Test func testRevokeMergesGrantOptionAndRefusesColumns() {
        let table = OracleSecurable.object(owner: "HR", name: "EMPLOYEES")
        #expect(statements.revokeStatements(
            [
                OracleGrant(privilege: "SELECT", securable: table, isGrantable: true),
                OracleGrant(privilege: "INSERT", securable: table),
                OracleGrant(privilege: "CREATE SESSION", securable: .system, isGrantable: true)
            ],
            from: "SCOTT"
        ) == [
            "REVOKE SELECT, INSERT ON \"HR\".\"EMPLOYEES\" FROM \"SCOTT\"",
            "REVOKE CREATE SESSION FROM \"SCOTT\""
        ])

        #expect(statements.revokeStatements(
            [OracleGrant(privilege: "UPDATE", securable: table, column: "SALARY")],
            from: "SCOTT"
        ) == nil)
    }

    @Test func testNamesAndPrivilegesAreEscaped() {
        let sql = statements.grantStatements(
            [
                OracleGrant(privilege: "SELECT; DROP USER X", securable: .system),
                OracleGrant(privilege: "SELECT", securable: .object(owner: "o\"wner", name: "t\"\u{301}"))
            ],
            to: "we\"ird"
        )

        #expect(sql == ["GRANT SELECT ON \"o\"\"wner\".\"t\"\"\u{301}\" TO \"we\"\"ird\""])
    }
}
