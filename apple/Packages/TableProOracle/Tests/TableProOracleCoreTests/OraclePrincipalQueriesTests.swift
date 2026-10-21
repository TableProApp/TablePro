import Foundation
@testable import TableProOracleCore
import Testing

struct OraclePrincipalQueriesTests {
    private let release19c = OracleServerRelease(major: 19, update: 3)
    private let release11g = OracleServerRelease(major: 11, update: 2)

    @Test func testDictionaryViewsAreOwnerQualified() {
        #expect(OraclePrincipalQueries.users(access: .dba, release: release19c).contains("FROM SYS.DBA_USERS"))
        #expect(OraclePrincipalQueries.roles(access: .dba).contains("FROM SYS.DBA_ROLES"))
        #expect(OraclePrincipalQueries.systemPrivileges(grantee: "X", access: .dba).contains("FROM SYS.DBA_SYS_PRIVS"))
        #expect(OraclePrincipalQueries.objectPrivileges(grantee: "X", access: .dba).contains("FROM SYS.DBA_TAB_PRIVS p"))
        #expect(OraclePrincipalQueries.columnPrivileges(grantee: "X", access: .dba).contains("FROM SYS.DBA_COL_PRIVS"))
        #expect(OraclePrincipalQueries.dbaProbe.contains("FROM SYS.DBA_USERS"))
    }

    @Test func testSessionAccessReadsTheViewsEveryAccountCanRead() {
        #expect(OraclePrincipalQueries.users(access: .session, release: release19c).contains("FROM SYS.ALL_USERS"))
        #expect(OraclePrincipalQueries.roles(access: .session).contains("SYS.USER_ROLE_PRIVS"))
        #expect(OraclePrincipalQueries.roleGrants(access: .session).contains("SYS.ROLE_ROLE_PRIVS"))
        #expect(OraclePrincipalQueries.systemPrivileges(grantee: "X", access: .session).contains("SYS.ROLE_SYS_PRIVS"))

        let objects = OraclePrincipalQueries.objectPrivileges(grantee: "X", access: .session)
        #expect(objects.contains("FROM SYS.ALL_TAB_PRIVS p"))
        #expect(objects.contains("p.TABLE_SCHEMA"))
        #expect(OraclePrincipalQueries.columnPrivileges(grantee: "X", access: .session).contains("FROM SYS.ALL_COL_PRIVS"))
    }

    // ORACLE_MAINTAINED arrived in 12.1; naming it on 11g fails the read with ORA-00904.
    @Test func testOracleMaintainedFilterFollowsTheRelease() {
        #expect(OraclePrincipalQueries.users(access: .dba, release: release19c).contains("ORACLE_MAINTAINED = 'N'"))
        #expect(!OraclePrincipalQueries.users(access: .dba, release: release11g).contains("ORACLE_MAINTAINED"))
        #expect(!OraclePrincipalQueries.searchObjects(matching: "x", limit: 5, release: release11g).contains("ORACLE_MAINTAINED"))
    }

    @Test func testGranteeIsALiteral() {
        #expect(OraclePrincipalQueries.systemPrivileges(grantee: "O'BRIEN", access: .dba).contains("GRANTEE = 'O''BRIEN'"))
        #expect(OraclePrincipalQueries.columns(owner: "HR", table: "IT'S").contains("TABLE_NAME = 'IT''S'"))
    }

    @Test func testSearchIsCaseInsensitiveAndEscapesWildcards() {
        let sql = OraclePrincipalQueries.searchObjects(matching: "emp_%", limit: 0, release: release19c)

        #expect(sql.contains(#"UPPER(OBJECT_NAME) LIKE '%EMP\_\%%' ESCAPE '\'"#))
        #expect(sql.contains("ROWNUM <= 1"))
    }

    @Test func testParseUsersReadsTheLock() {
        let users = OraclePrincipalQueries.parseUsers([
            ["SCOTT", "OPEN"],
            ["OLD", "EXPIRED & LOCKED"],
            ["TEMP", "LOCKED(TIMED)"],
            ["ANY", nil]
        ])

        #expect(users.map(\.isLocked) == [false, true, true, false])
    }

    @Test func testParsePrivileges() {
        #expect(OraclePrincipalQueries.parseSystemPrivileges([["CREATE SESSION", "YES"], ["CREATE TABLE", "NO"]]) == [
            OracleGrant(privilege: "CREATE SESSION", securable: .system, isGrantable: true),
            OracleGrant(privilege: "CREATE TABLE", securable: .system)
        ])
        #expect(OraclePrincipalQueries.parseObjectPrivileges([["HR", "EMPLOYEES", "SELECT", "NO"]]) == [
            OracleGrant(privilege: "SELECT", securable: .object(owner: "HR", name: "EMPLOYEES"))
        ])
        #expect(OraclePrincipalQueries.parseColumnPrivileges([["HR", "EMPLOYEES", "SALARY", "UPDATE", "YES"]]) == [
            OracleGrant(
                privilege: "UPDATE",
                securable: .object(owner: "HR", name: "EMPLOYEES"),
                column: "SALARY",
                isGrantable: true
            )
        ])
    }

    @Test func testMissingViewIsOnlyORA00942() {
        #expect(OraclePrincipalQueries.isMissingView(.queryFailed("ORA-00942: table or view does not exist")))
        #expect(!OraclePrincipalQueries.isMissingView(.queryFailed("ORA-01031: insufficient privileges")))
        #expect(!OraclePrincipalQueries.isMissingView(.connectionClosed))
    }

    @Test func testQuotingDoublesAQuoteBeforeACombiningMark() {
        #expect(OracleSchemaQueries.quoteIdentifier("a\"\u{301}") == "\"a\"\"\u{301}\"")
        #expect(OracleSchemaQueries.escapeLiteral("a'\u{301}") == "a''\u{301}")
    }
}
