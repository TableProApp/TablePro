import Foundation
@testable import TableProMobile
import TableProDatabase
import TableProModels
import Testing

struct ReadOnlyFunctionGuardTests {
    @Test("Without the engine's read-only mode, Read-Only refuses a call off the built-in list where functions can write", arguments: [
        DatabaseType.postgresql, .mysql, .mariadb, .oceanbase, .oracle,
    ])
    func refusesAnUnlistedCallWithoutReadOnlyMode(type: DatabaseType) {
        #expect(ReadOnlyFunctionGuard.refuses(
            "SELECT purge_orders()", databaseType: type, level: .readOnly, enforcesReadOnlyMode: false
        ))
        #expect(ReadOnlyFunctionGuard.refuses(
            "SELECT app.count(id) FROM orders", databaseType: type, level: .readOnly, enforcesReadOnlyMode: false
        ))
    }

    @Test("In the engine's read-only mode the call runs, since the server refuses what it writes", arguments: [
        DatabaseType.postgresql, .mysql, .mariadb,
    ])
    func runsAnUnlistedCallInReadOnlyMode(type: DatabaseType) {
        #expect(!ReadOnlyFunctionGuard.refuses(
            "SELECT purge_orders()", databaseType: type, level: .readOnly, enforcesReadOnlyMode: true
        ))
    }

    @Test("PostgreSQL, MySQL and MariaDB drivers hold Read-Only in the engine; Oracle, OceanBase, TiDB, Redshift and old servers do not")
    func driversSayWhichRunInReadOnlyMode() throws {
        let factory = IOSDriverFactory()
        func mode(_ type: DatabaseType) throws -> Bool {
            let connection = DatabaseConnection(name: "Shop", type: type, host: "db.example.com")
            return try factory.createDriver(for: connection, password: nil).enforcesReadOnlyMode
        }
        #expect(try mode(.postgresql))
        #expect(try mode(.mysql))
        #expect(try mode(.mariadb))
        #expect(try !mode(.redshift))
        #expect(try !mode(.oracle))
        #expect(try !mode(.oceanbase))
        #expect(try !mode(.tidb))

        #expect(MySQLDriver.runsReadOnlyTransactions(for: .mysql, banner: "8.4.13"))
        #expect(MySQLDriver.runsReadOnlyTransactions(for: .mysql, banner: "10.11.6-MariaDB"))
        #expect(!MySQLDriver.runsReadOnlyTransactions(for: .mysql, banner: "5.6.4-log"))
        #expect(!MySQLDriver.runsReadOnlyTransactions(for: .mariadb, banner: "5.5.64-MariaDB"))
        #expect(!MySQLDriver.runsReadOnlyTransactions(for: .mysql, banner: "8.0.11-TiDB-v8.5.1"))
        #expect(!MySQLDriver.runsReadOnlyTransactions(for: .oceanbase, banner: "5.7.25-OceanBase_CE-v4.2.1.0"))
    }

    @Test("A server too old for READ ONLY keeps the refusal")
    func oldServerKeepsTheRefusal() {
        let mode = MySQLDriver.runsReadOnlyTransactions(for: .mysql, banner: "5.6.4-log")
        #expect(ReadOnlyFunctionGuard.refuses(
            "SELECT purge_orders()", databaseType: .mysql, level: .readOnly, enforcesReadOnlyMode: mode
        ))
    }

    @Test("Built-ins, a cast to the engine's own type and a plain EXPLAIN run", arguments: [
        (DatabaseType.postgresql, "SELECT COUNT(*), LOWER(name), NOW() FROM orders WHERE total::numeric(10, 2) > 1"),
        (.postgresql, "EXPLAIN SELECT purge_orders()"),
        (.mysql, "SELECT DATE_FORMAT(created_at, '%Y-%m'), CAST(total AS DECIMAL(10, 2)) FROM orders"),
        (.oracle, "SELECT NVL(note, 'x'), TO_CHAR(created, 'YYYY') FROM orders"),
    ])
    func runsBuiltins(type: DatabaseType, sql: String) {
        #expect(!ReadOnlyFunctionGuard.refuses(sql, databaseType: type, level: .readOnly, enforcesReadOnlyMode: false))
    }

    @Test("Only Read-Only refuses, and only where a function a query calls can write")
    func refusesOnlyAtReadOnlyWhereFunctionsWrite() {
        let sql = "SELECT purge_orders()"
        #expect(!ReadOnlyFunctionGuard.refuses(sql, databaseType: .postgresql, level: .confirmWrites, enforcesReadOnlyMode: false))
        #expect(!ReadOnlyFunctionGuard.refuses(sql, databaseType: .postgresql, level: .off, enforcesReadOnlyMode: false))
        #expect(!ReadOnlyFunctionGuard.refuses(sql, databaseType: .mssql, level: .readOnly, enforcesReadOnlyMode: false))
        #expect(!ReadOnlyFunctionGuard.refuses(sql, databaseType: .sqlite, level: .readOnly, enforcesReadOnlyMode: false))
    }

    @Test("A read at Read-Only on an idle session runs in the read-only mode")
    func idleReadRunsInReadOnlyMode() async {
        let driver = MockDatabaseDriver()
        driver.enforcesReadOnlyMode = true
        driver.scriptedTransactionState = .idle

        #expect(await ReadOnlyFunctionGuard.runsInReadOnlyMode(writes: false, level: .readOnly, driver: driver))
        #expect(driver.transactionStateReads == 1)
    }

    @Test("A session holding a transaction, or one it cannot name, runs the read as it is", arguments: [
        DriverTransactionState.explicitTransaction, .implicitTransaction, .abortedTransaction, .unknown,
    ])
    func busySessionRunsAsItIs(state: DriverTransactionState) async {
        let driver = MockDatabaseDriver()
        driver.enforcesReadOnlyMode = true
        driver.scriptedTransactionState = state

        #expect(await !ReadOnlyFunctionGuard.runsInReadOnlyMode(writes: false, level: .readOnly, driver: driver))
    }

    @Test("A write, a level below Read-Only and a driver without the mode never ask the session")
    func otherRunsNeverAskTheSession() async {
        let withMode = MockDatabaseDriver()
        withMode.enforcesReadOnlyMode = true
        withMode.scriptedTransactionState = .idle
        let withoutMode = MockDatabaseDriver()
        withoutMode.scriptedTransactionState = .idle

        #expect(await !ReadOnlyFunctionGuard.runsInReadOnlyMode(writes: true, level: .readOnly, driver: withMode))
        #expect(await !ReadOnlyFunctionGuard.runsInReadOnlyMode(writes: false, level: .confirmWrites, driver: withMode))
        #expect(await !ReadOnlyFunctionGuard.runsInReadOnlyMode(writes: false, level: .readOnly, driver: withoutMode))
        #expect(withMode.transactionStateReads == 0)
        #expect(withoutMode.transactionStateReads == 0)
    }
}
