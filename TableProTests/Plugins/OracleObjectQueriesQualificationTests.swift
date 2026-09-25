//
//  OracleObjectQueriesQualificationTests.swift
//  TableProTests
//
//  The Oracle plugin's routine, trigger and index catalog SQL names every dictionary view with its SYS owner, so a
//  same-named object planted in the current schema cannot shadow it. Measured on Oracle 23ai.
//

import Foundation
import Testing

@testable import TablePro

struct OracleObjectQueriesQualificationTests {
    private static let bareDictionary = try! NSRegularExpression(
        pattern: #"\b(ALL|DBA|USER)_[A-Z_]+\b|\bDUAL\b|V\$[A-Z_]+"#
    )

    private func bareToken(in sql: String) -> String? {
        let stripped = sql.replacingOccurrences(of: #"SYS\.[A-Z_$0-9]+"#, with: " ", options: .regularExpression)
        let range = NSRange(stripped.startIndex..., in: stripped)
        guard let match = Self.bareDictionary.firstMatch(in: stripped, range: range),
              let matchRange = Range(match.range, in: stripped) else {
            return nil
        }
        return String(stripped[matchRange])
    }

    @Test("Routine and trigger catalog SQL is owner-qualified")
    func routineAndTriggerQueriesAreQualified() {
        let queries = [
            OracleObjectQueries.routineList(schema: "HR"),
            OracleObjectQueries.routineSource(schema: "HR", name: "P", type: "PROCEDURE"),
            OracleObjectQueries.triggerList(schema: "HR", table: nil),
            OracleObjectQueries.triggerList(schema: "HR", table: "EMPLOYEES")
        ]
        for sql in queries {
            #expect(bareToken(in: sql) == nil, "unqualified dictionary name in:\n\(sql)")
        }
    }

    @Test("Index dump SQL is owner-qualified")
    func indexQueryIsQualified() {
        let sql = OracleIndexStatements.query(schema: "HR", table: "EMPLOYEES")
        #expect(bareToken(in: sql) == nil, "unqualified dictionary name in:\n\(sql)")
        #expect(sql.contains("SYS.ALL_INDEXES"))
        #expect(sql.contains("SYS.ALL_IND_COLUMNS"))
    }
}
