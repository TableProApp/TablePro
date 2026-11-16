//
//  ClickHouseDropRoutineTests.swift
//  ClickHouseDriverTests
//

import Foundation
import TableProPluginKit
import Testing

// ClickHouse has no DROP ROUTINE, so a dump with Drop ticked on a user function restores only through this statement.
struct ClickHouseDropRoutineTests {
    private var driver: ClickHousePluginDriver {
        ClickHousePluginDriver(config: DriverConnectionConfig(
            host: "localhost",
            port: 8_123,
            username: "default",
            password: "",
            database: "analytics",
            ssl: SSLConfiguration(),
            additionalFields: [:]
        ))
    }

    @Test("A user function drops by its bare name, whatever database the export names")
    func dropsFunctionByBareName() {
        let sql = driver.generateDropRoutineSQL(name: "linear_eq", signature: nil, schema: "analytics", isFunction: true)
        #expect(sql == "DROP FUNCTION IF EXISTS `linear_eq`")
    }

    @Test("A backtick and a backslash in the name stay inside the identifier")
    func quotesTheName() {
        #expect(ClickHouseObjectQueries.dropFunction(name: #"a`b\c"#) == #"DROP FUNCTION IF EXISTS `a\`b\\c`"#)
    }
}
