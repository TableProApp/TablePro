import Foundation
import Testing

@testable import TableProMySQLCore

struct MySQLSessionStatementsTests {
    @Test("The capture query asks for the names in the order given")
    func captureQueryListsNames() {
        let query = MySQLSessionStatements.captureQuery(names: ["sql_mode", "time_zone", "foreign_key_checks"])
        #expect(query == "SHOW SESSION VARIABLES WHERE Variable_name IN ('sql_mode', 'time_zone', 'foreign_key_checks')")
    }

    @Test("A name that is not a setting name is left out of the capture query")
    func captureQueryDropsForeignNames() {
        let query = MySQLSessionStatements.captureQuery(names: ["sql_mode", "x') OR ('1", "time_zone"])
        #expect(query == "SHOW SESSION VARIABLES WHERE Variable_name IN ('sql_mode', 'time_zone')")
        #expect(MySQLSessionStatements.captureQuery(names: []) == nil)
        #expect(MySQLSessionStatements.captureQuery(names: ["@@sql_mode"]) == nil)
    }

    @Test("Only lowercase letters and underscores make a setting name", arguments: [
        ("sql_mode", true),
        ("character_set_results", true),
        ("", false),
        ("SQL_MODE", false),
        ("sql_mode2", false),
        ("@@sql_mode", false),
        ("sql_mode = ''", false),
        ("sql_mode;", false),
        ("time_zone/*", false),
    ])
    func settingNames(_ name: String, _ isValid: Bool) {
        #expect(MySQLSessionStatements.isSettingName(name) == isValid)
    }

    @Test("A nil value is SQL NULL, any other value a quoted literal")
    func assignmentSpellsNullAndLiterals() {
        #expect(MySQLSessionStatements.assignment(name: "character_set_results", value: nil)
            == "SET SESSION character_set_results = NULL")
        #expect(MySQLSessionStatements.assignment(name: "sql_mode", value: "") == "SET SESSION sql_mode = ''")
        #expect(MySQLSessionStatements.assignment(name: "time_zone", value: "+00:00") == "SET SESSION time_zone = '+00:00'")
    }

    @Test("A value is escaped the way every plugin statement is, before the session respells it")
    func assignmentEscapesValues() {
        #expect(MySQLSessionStatements.assignment(name: "time_zone", value: #"it's\here"#)
            == #"SET SESSION time_zone = 'it''s\\here'"#)
    }

    /// `SHOW` reports a boolean as `ON` or `OFF`, which `SET` takes back quoted, where `'1'` is refused with 1231.
    @Test("ON and OFF pass through as SHOW reported them")
    func booleansPassThrough() {
        #expect(MySQLSessionStatements.reportedValue(name: "foreign_key_checks", value: "OFF") == "OFF")
        #expect(MySQLSessionStatements.assignment(name: "foreign_key_checks", value: "OFF")
            == "SET SESSION foreign_key_checks = 'OFF'")
        #expect(MySQLSessionStatements.assignment(name: "unique_checks", value: "ON") == "SET SESSION unique_checks = 'ON'")
    }

    @Test("An empty character set or collation is NULL, and an empty sql_mode stays empty")
    func emptyReportedValues() {
        #expect(MySQLSessionStatements.reportedValue(name: "character_set_results", value: "") == nil)
        #expect(MySQLSessionStatements.reportedValue(name: "collation_connection", value: "") == nil)
        #expect(MySQLSessionStatements.reportedValue(name: "sql_mode", value: "") == "")
        #expect(MySQLSessionStatements.reportedValue(name: "time_zone", value: nil) == nil)
        #expect(MySQLSessionStatements.reportedValue(name: "character_set_results", value: "utf8mb4") == "utf8mb4")
    }

    @Test("A name that is not a setting name gets no statement")
    func assignmentRefusesForeignNames() {
        #expect(MySQLSessionStatements.assignment(name: "sql_mode = '', time_zone", value: "x") == nil)
        #expect(MySQLSessionStatements.assignment(name: "", value: nil) == nil)
    }
}
