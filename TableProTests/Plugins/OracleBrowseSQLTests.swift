//
//  OracleBrowseSQLTests.swift
//  TableProTests
//
//  The Oracle plugin's table paging and filter SQL. Every query below was run against Oracle 23ai under the default
//  NLS_DATE_FORMAT DD-MON-RR and found the row it filters for.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct OracleBrowseSQLTests {
    private func filtered(_ column: String, _ op: String, _ value: String, kind: PluginColumnKind?) -> String {
        OracleBrowseSQL.filteredQuery(
            qualifiedTable: "\"T\"",
            filters: [PluginQueryFilter(column: column, op: op, value: value)],
            logicMode: "and",
            sortColumns: [],
            columns: [column],
            limit: 10,
            offset: 0,
            columnKinds: kind.map { [column: $0] } ?? [:]
        )
    }

    /// `ORDER BY 1` fails with ORA-22848 when the first column is a LOB.
    @Test("A page with no sort has no ORDER BY")
    func browseWithoutSort() {
        let sql = OracleBrowseSQL.browseQuery(
            qualifiedTable: "\"HR\".\"T\"", sortColumns: [], columns: ["NOTE", "ID"], limit: 100, offset: 200
        )
        #expect(sql == "SELECT * FROM \"HR\".\"T\" OFFSET 200 ROWS FETCH NEXT 100 ROWS ONLY")
    }

    @Test("A sorted page orders by the sorted column")
    func browseWithSort() {
        let sql = OracleBrowseSQL.browseQuery(
            qualifiedTable: "\"T\"", sortColumns: [(columnIndex: 1, ascending: false)], columns: ["NOTE", "ID"],
            limit: 10, offset: 0
        )
        #expect(sql == "SELECT * FROM \"T\" ORDER BY \"ID\" DESC OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY")
    }

    @Test("A filtered page with no sort has no ORDER BY either")
    func filteredWithoutSort() {
        #expect(filtered("N", "=", "5", kind: .integer) == "SELECT * FROM \"T\" WHERE \"N\" = 5 OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY")
    }

    /// A quoted `'2026-10-06'` is read through NLS_DATE_FORMAT and fails with ORA-01861.
    @Test("A date or timestamp value against a temporal column is an ANSI literal")
    func temporalLiterals() {
        let cases: [(value: String, literal: String)] = [
            ("2026-10-06", "DATE '2026-10-06'"),
            ("2026-10-06 15:22:20", "TIMESTAMP '2026-10-06 15:22:20'"),
            ("2026-10-06 15:22:20.050", "TIMESTAMP '2026-10-06 15:22:20.050'"),
            ("2026-10-06 15:22:20.000001+02:00", "TIMESTAMP '2026-10-06 15:22:20.000001+02:00'"),
            ("2026-10-06 15:22:20 -05:30", "TIMESTAMP '2026-10-06 15:22:20 -05:30'"),
            ("2026-10-06T15:22:20", "TIMESTAMP '2026-10-06 15:22:20'"),
            (" 2026-10-06 ", "DATE '2026-10-06'")
        ]
        for testCase in cases {
            #expect(OracleBrowseSQL.filterValue(testCase.value, kind: .other) == testCase.literal, "\(testCase.value)")
        }
    }

    /// Measured on 23ai with the session at `+07:00` against a `+00:00` database: a TIMESTAMP WITH LOCAL TIME ZONE
    /// column matches the text it reads as, with its offset or without one in the session's zone.
    @Test("A local-time-zone value with or without its offset is a timestamp literal")
    func localTimeZoneLiterals() {
        #expect(filtered("TL", "=", "2026-10-06 08:04:05.123456+07:00", kind: .other)
            == "SELECT * FROM \"T\" WHERE \"TL\" = TIMESTAMP '2026-10-06 08:04:05.123456+07:00' "
            + "OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY")
        #expect(OracleBrowseSQL.filterValue("2026-10-06 08:04:05.123456", kind: .other)
            == "TIMESTAMP '2026-10-06 08:04:05.123456'")
    }

    /// Each of these is an error as an ANSI literal (ORA-01861, ORA-01873), so it keeps today's quoted text.
    @Test("Text that is not a whole date or timestamp stays a quoted string")
    func nonTemporalShapes() {
        for value in ["2026-10-06 15:22", "26-10-06", "2026-10-06 15:22:20.1234567891", "06-OCT-26", "x' OR 1=1 --"] {
            let quoted = "'\(value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "'", with: "''"))'"
            #expect(OracleBrowseSQL.filterValue(value, kind: .other) == quoted, "\(value)")
        }
    }

    /// A date literal against a text column would convert the column, which fails on any row that is not a date.
    @Test("A text, numeric or unknown column keeps its own literal")
    func otherKindsKeepTheirLiterals() {
        #expect(OracleBrowseSQL.filterValue("2026-10-06", kind: .text) == "'2026-10-06'")
        #expect(OracleBrowseSQL.filterValue("2026-10-06", kind: nil) == "'2026-10-06'")
        #expect(OracleBrowseSQL.filterValue("12.5", kind: .decimal) == "12.5")
    }

    @Test("Every comparison operator on a temporal column uses the literal")
    func temporalOperators() {
        #expect(filtered("D", "BETWEEN", "2026-10-06,2026-10-06 23:59:59", kind: .other)
            == "SELECT * FROM \"T\" WHERE \"D\" BETWEEN DATE '2026-10-06' AND TIMESTAMP '2026-10-06 23:59:59' "
            + "OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY")
        #expect(filtered("D", "IN", "2026-10-06 15:22:20, 2026-01-01", kind: .other)
            == "SELECT * FROM \"T\" WHERE \"D\" IN (TIMESTAMP '2026-10-06 15:22:20', DATE '2026-01-01') "
            + "OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY")
        #expect(filtered("D", ">=", "2026-10-06", kind: .other)
            == "SELECT * FROM \"T\" WHERE \"D\" >= DATE '2026-10-06' OFFSET 0 ROWS FETCH NEXT 10 ROWS ONLY")
    }

    @Test("Names are quoted and qualified")
    func qualifiedName() {
        #expect(OracleBrowseSQL.qualifiedName(schema: "HR", table: "Order \"Lines\"") == "\"HR\".\"Order \"\"Lines\"\"\"")
        #expect(OracleBrowseSQL.qualifiedName(schema: nil, table: "T") == "\"T\"")
        #expect(OracleBrowseSQL.qualifiedName(schema: "", table: "T") == "\"T\"")
    }
}
