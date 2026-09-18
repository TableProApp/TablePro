//
//  MySQLQueryTimeoutTests.swift
//  TableProTests
//
//  Banners and behaviour measured with libmariadb 3.4.4 against MySQL 5.5.62, 5.6.51, 5.7.44 and
//  8.4.11 and MariaDB 5.5.64, 10.0.38, 10.1.48 and 10.6.28.
//

import Foundation
import Testing

@Suite("MySQL query timeout enforcement")
struct MySQLQueryTimeoutTests {
    @Test("A server timeout starts at MySQL 5.7.8")
    func mysqlFloor() {
        for banner in ["5.5.62", "5.6.51", "5.7.7"] {
            #expect(mysqlQueryTimeoutEnforcement(seconds: 30, flavor: .mysql, banner: banner)
                == .clientDeadline(MySQLStatementDeadline(seconds: 30, scope: .selectStatements)))
        }
        for banner in ["5.7.8", "5.7.44", "8.4.11"] {
            #expect(mysqlQueryTimeoutEnforcement(seconds: 30, flavor: .mysql, banner: banner)
                == .serverStatements(["SET SESSION max_execution_time = 30000"]))
        }
    }

    @Test("A server timeout starts at MariaDB 10.1.1, and covers every statement below it")
    func mariadbFloor() {
        for banner in ["5.5.64-MariaDB-1~trusty", "10.0.38-MariaDB-1~xenial", "10.1.0-MariaDB"] {
            #expect(mysqlQueryTimeoutEnforcement(seconds: 30, flavor: .mariadb, banner: banner)
                == .clientDeadline(MySQLStatementDeadline(seconds: 30, scope: .everyStatement)))
        }
        for banner in ["10.1.1-MariaDB", "10.1.48-MariaDB-1~bionic"] {
            #expect(mysqlQueryTimeoutEnforcement(seconds: 30, flavor: .mariadb, banner: banner)
                == .serverStatements(["SET SESSION max_statement_time = 30"]))
        }
    }

    @Test("An unreadable banner takes the client deadline rather than assuming a modern server")
    func unknownBanner() {
        #expect(mysqlQueryTimeoutEnforcement(seconds: 30, flavor: .mysql, banner: nil)
            == .clientDeadline(MySQLStatementDeadline(seconds: 30, scope: .selectStatements)))
        #expect(!MySQLServerVersion.hasStatementTimeout(banner: "unknown", flavor: .mysql))
    }

    @Test("TiDB, OceanBase and Databend keep their own statements whatever the banner says")
    func variantsKeepTheirStatements() {
        let flavors: [MySQLServerFlavor] = [
            .tidb(version: nil),
            .oceanbase(version: MySQLEngineVersion(major: 4, minor: 4, patch: 2)),
            .databend
        ]
        for flavor in flavors {
            #expect(mysqlQueryTimeoutEnforcement(seconds: 30, flavor: flavor, banner: "5.6.25")
                == .serverStatements(flavor.queryTimeoutStatements(seconds: 30)))
        }
    }

    @Test("A MySQL client deadline times a SELECT and nothing else")
    func mysqlDeadlineScope() {
        let deadline = mysqlClientDeadline(seconds: 5, flavor: .mysql)
        let selects = ["SELECT 1", "  select 1", "(SELECT SLEEP(5))", "/* lead */ SELECT 1", "-- c\nSELECT 1"]
        for sql in selects {
            #expect(deadline.applies(to: sql))
        }
        let others = ["SHOW TABLES", "CALL p()", "DO SLEEP(5)", "INSERT INTO t SELECT 1", "UPDATE t SET a = 1"]
        for sql in others {
            #expect(!deadline.applies(to: sql))
        }
    }

    @Test("A MariaDB client deadline times every statement")
    func mariadbDeadlineScope() {
        let deadline = mysqlClientDeadline(seconds: 5, flavor: .mariadb)
        let statements = [
            "SELECT 1", "SHOW TABLES", "CALL p()", "DO SLEEP(5)",
            "INSERT INTO t SELECT 1", "UPDATE t SET a = 1"
        ]
        for sql in statements {
            #expect(deadline.applies(to: sql))
        }
    }

    @Test("No timeout applies to nothing")
    func zeroSecondsAppliesToNothing() {
        #expect(!MySQLStatementDeadline(seconds: 0, scope: .everyStatement).applies(to: "SELECT 1"))
        #expect(!MySQLStatementDeadline(seconds: 0, scope: .selectStatements).applies(to: "SELECT 1"))
    }

    @Test("Only ERROR 1193 means the server has no statement timeout")
    func rejectionCode() {
        #expect(mysqlRejectsStatementTimeout(code: 1_193))
        #expect(!mysqlRejectsStatementTimeout(code: 1_064))
        #expect(!mysqlRejectsStatementTimeout(code: 1_227))
    }

    @Test("A statement stopped by the deadline is told apart from one the server refused")
    func failureCause() {
        #expect(cause(errno: 1_317, deadlineExpired: true) == .deadlineExceeded)
        #expect(cause(errno: 1_317, deadlineExpired: false) == .server)
        #expect(cause(errno: 3_024, deadlineExpired: true) == .server)
        #expect(mysqlStatementFailureCause(
            errno: 1_105, message: "AbortedQuery: killed", flavor: .databend,
            deadlineExpired: true, waited: .seconds(1), socketTimeoutSeconds: 31
        ) == .deadlineExceeded)
    }

    @Test("A lost connection past the socket timeout is the client's own, not the server's")
    func socketTimeoutCause() {
        #expect(cause(errno: 2_013, waited: .seconds(31)) == .outlastedSocketTimeout)
        #expect(cause(errno: 2_013, waited: .milliseconds(30_999)) == .server)
        #expect(cause(errno: 2_013, waited: .seconds(31), socketTimeoutSeconds: 0) == .server)
        #expect(cause(errno: 1_064, waited: .seconds(31)) == .server)
    }

    /// OceanBase sends two, and a server that takes `ob_query_timeout` and answers `ERROR 1193` to
    /// `max_execution_time` is already enforcing a timeout of its own. A client-side deadline on top
    /// of it stops the statement twice, and OceanBase absorbs no latched kill, so the second
    /// `KILL QUERY` fails whatever the session runs next with `ERROR 1317`.
    @Test("A refusal after the server has taken a statement leaves the server's timeout alone")
    func refusalAfterAnAcceptedStatementKeepsTheServerTimeout() {
        let flavor = MySQLServerFlavor.oceanbase(version: MySQLEngineVersion(major: 4, minor: 4, patch: 2))
        #expect(flavor.queryTimeoutStatements(seconds: 30).count == 2)

        var installation = MySQLQueryTimeoutInstallation(seconds: 30, flavor: flavor)
        #expect(installation.accepted() == .sendNextStatement)
        #expect(installation.refusedAsUnknownVariable() == .sendNextStatement)
    }

    @Test("A server that refuses the first statement is timed by the client instead")
    func refusalOfTheFirstStatementAdoptsTheClientDeadline() {
        var installation = MySQLQueryTimeoutInstallation(seconds: 30, flavor: .mysql)
        #expect(installation.refusedAsUnknownVariable()
            == .adopt(mysqlClientDeadline(seconds: 30, flavor: .mysql)))
    }

    /// Any other failure says nothing about whether the server has a timeout, so no client deadline
    /// is installed. Returning without adopting left the deadline a previous call had built from
    /// another `seconds` value stopping the user's statements.
    @Test("A failure that is not ERROR 1193 clears the deadline rather than keeping an older one")
    func otherFailuresAdoptNoDeadline() {
        var installation = MySQLQueryTimeoutInstallation(seconds: 30, flavor: .mariadb)
        #expect(installation.failed() == .adopt(nil))
        #expect(installation.accepted() == .sendNextStatement)
        #expect(installation.failed() == .adopt(nil))
    }

    private func cause(
        errno: UInt32,
        deadlineExpired: Bool = false,
        waited: Duration = .seconds(1),
        socketTimeoutSeconds: UInt32 = 31
    ) -> MySQLStatementFailureCause {
        mysqlStatementFailureCause(
            errno: errno,
            message: "Query execution was interrupted",
            flavor: .mysql,
            deadlineExpired: deadlineExpired,
            waited: waited,
            socketTimeoutSeconds: socketTimeoutSeconds
        )
    }
}
