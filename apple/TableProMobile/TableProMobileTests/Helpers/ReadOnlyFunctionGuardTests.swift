import Foundation
@testable import TableProMobile
import TableProModels
import Testing

struct ReadOnlyFunctionGuardTests {
    @Test("Read-Only refuses a call off the built-in list on an engine whose functions can write", arguments: [
        DatabaseType.postgresql, .mysql, .mariadb, .oceanbase, .oracle,
    ])
    func refusesAnUnlistedCall(type: DatabaseType) {
        #expect(ReadOnlyFunctionGuard.refuses("SELECT purge_orders()", databaseType: type, level: .readOnly))
        #expect(ReadOnlyFunctionGuard.refuses("SELECT app.count(id) FROM orders", databaseType: type, level: .readOnly))
    }

    @Test("Built-ins, a cast to the engine's own type and a plain EXPLAIN run", arguments: [
        (DatabaseType.postgresql, "SELECT COUNT(*), LOWER(name), NOW() FROM orders WHERE total::numeric(10, 2) > 1"),
        (.postgresql, "EXPLAIN SELECT purge_orders()"),
        (.mysql, "SELECT DATE_FORMAT(created_at, '%Y-%m'), CAST(total AS DECIMAL(10, 2)) FROM orders"),
        (.oracle, "SELECT NVL(note, 'x'), TO_CHAR(created, 'YYYY') FROM orders"),
    ])
    func runsBuiltins(type: DatabaseType, sql: String) {
        #expect(!ReadOnlyFunctionGuard.refuses(sql, databaseType: type, level: .readOnly))
    }

    @Test("Only Read-Only refuses, and only where a function a query calls can write")
    func refusesOnlyAtReadOnlyWhereFunctionsWrite() {
        #expect(!ReadOnlyFunctionGuard.refuses("SELECT purge_orders()", databaseType: .postgresql, level: .confirmWrites))
        #expect(!ReadOnlyFunctionGuard.refuses("SELECT purge_orders()", databaseType: .postgresql, level: .off))
        #expect(!ReadOnlyFunctionGuard.refuses("SELECT purge_orders()", databaseType: .mssql, level: .readOnly))
        #expect(!ReadOnlyFunctionGuard.refuses("SELECT purge_orders()", databaseType: .sqlite, level: .readOnly))
    }
}
