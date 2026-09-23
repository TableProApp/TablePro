@testable import TableProOracleCore
import XCTest

/// Every data dictionary object the shared Oracle core names in SQL is owner-qualified, so a table, view or package a
/// user plants in the current schema, or in a schema the reader switched into, cannot shadow it. Measured on Oracle
/// 23ai: a bare `ALL_TABLES` in the current schema captured the tables read, and `SYS.ALL_TABLES` did not.
final class OracleDictionaryQualificationTests: XCTestCase {
    /// A dictionary token that must never appear without its `SYS` owner in front of it. The queries give their
    /// tables lowercase aliases, so a name after one (`c.USER_GENERATED`, a column of `ALL_TAB_COLS`) is a column and
    /// names no dictionary object, while an uppercase owner in front of a view is still caught.
    private static let bareDictionary = try! NSRegularExpression(
        pattern: #"(?<![a-z]\.)\b(ALL|DBA|USER)_[A-Z_]+\b|\bDUAL\b|V\$[A-Z_]+"#
    )

    /// Strips every `SYS.`-qualified reference, then fails if any dictionary token is left bare.
    private func assertFullyQualified(_ sql: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let stripped = sql.replacingOccurrences(
            of: #"SYS\.[A-Z_$0-9]+"#, with: " ", options: .regularExpression
        )
        let range = NSRange(stripped.startIndex..., in: stripped)
        let match = Self.bareDictionary.firstMatch(in: stripped, range: range)
        if let match, let matchRange = Range(match.range, in: stripped) {
            XCTFail("\(label) names \(stripped[matchRange]) without its SYS owner:\n\(sql)", file: file, line: line)
        }
    }

    private var everySchemaQuery: [(String, String)] {
        [
            ("ping", OracleSchemaQueries.ping),
            ("currentSchema", OracleSchemaQueries.currentSchema),
            ("serverVersion", OracleSchemaQueries.serverVersion),
            ("users", OracleSchemaQueries.users),
            ("tables", OracleSchemaQueries.tables(schema: "HR")),
            ("partitions", OracleSchemaQueries.partitions(schema: "HR", table: "T")),
            ("subpartitions", OracleSchemaQueries.subpartitions(schema: "HR", table: "T")),
            ("columns 11g", OracleSchemaQueries.columns(schema: "HR", table: "T", release: OracleServerRelease(major: 11))),
            ("columns 23ai", OracleSchemaQueries.columns(schema: "HR", table: "T", release: OracleServerRelease(major: 23))),
            ("indexes", OracleSchemaQueries.indexes(schema: "HR", table: "T")),
            ("foreignKeys", OracleSchemaQueries.foreignKeys(schema: "HR", table: "T")),
            ("allColumns 11g", OracleSchemaQueries.allColumns(schema: "HR", release: OracleServerRelease(major: 11))),
            ("allColumns 23ai", OracleSchemaQueries.allColumns(schema: "HR", release: OracleServerRelease(major: 23))),
            ("allForeignKeys", OracleSchemaQueries.allForeignKeys(schema: "HR")),
            ("databaseSummaries", OracleSchemaQueries.databaseSummaries),
            ("schemaSegmentSizes", OracleSchemaQueries.schemaSegmentSizes),
            ("databaseTableCount", OracleSchemaQueries.databaseTableCount(schema: "HR")),
            ("tableMetadata", OracleSchemaQueries.tableMetadata(schema: "HR", table: "T")),
            ("viewComment", OracleSchemaQueries.viewComment(schema: "HR", view: "V")),
            ("segmentSize own", OracleSchemaQueries.segmentSize(schema: "HR", table: "T", ownedByCurrentSchema: true)),
            ("segmentSize other", OracleSchemaQueries.segmentSize(schema: "HR", table: "T", ownedByCurrentSchema: false)),
            ("viewDefinition", OracleSchemaQueries.viewDefinition(schema: "HR", view: "V")),
            ("allTablesMetadata", OracleSchemaQueries.allTablesMetadata(schema: "HR")),
            ("columnNamesAndTypes", OracleSchemaQueries.columnNamesAndTypes(schema: "HR", table: "T")),
            ("errorsQuery named", OraclePLSQLUnit(type: "PROCEDURE", owner: "HR", name: "P").errorsQuery),
            ("errorsQuery current", OraclePLSQLUnit(type: "PROCEDURE", owner: nil, name: "P").errorsQuery)
        ]
    }

    func testEverySchemaQueryIsOwnerQualified() {
        for (label, sql) in everySchemaQuery {
            assertFullyQualified(sql, label)
        }
    }

    func testThePerformanceViewUsesTheUnderscoreForm() {
        XCTAssertEqual(OracleDictionary.versionView, "SYS.V_$VERSION")
        XCTAssertEqual(OracleDictionary.performanceView("V$SESSION"), "SYS.V_$SESSION")
        XCTAssertEqual(OracleDictionary.performanceView("GV$SESSION"), "SYS.GV_$SESSION")
        XCTAssertTrue(OracleSchemaQueries.serverVersion.contains("SYS.V_$VERSION"))
        XCTAssertFalse(OracleSchemaQueries.serverVersion.contains("V$VERSION"))
    }

    func testDualAndTheSegmentViewsAreQualified() {
        XCTAssertEqual(OracleDictionary.dual, "SYS.DUAL")
        XCTAssertTrue(OracleSchemaQueries.ping.contains("SYS.DUAL"))
        XCTAssertTrue(
            OracleSchemaQueries.segmentSize(schema: "HR", table: "T", ownedByCurrentSchema: true)
                .contains("SYS.USER_SEGMENTS")
        )
        XCTAssertTrue(
            OracleSchemaQueries.segmentSize(schema: "HR", table: "T", ownedByCurrentSchema: false)
                .contains("SYS.DBA_SEGMENTS")
        )
    }

    /// `ALL_SEGMENTS` does not exist on Oracle (ORA-00942 even as `SYSTEM`), so no query may name it.
    func testNoQueryNamesTheNonexistentAllSegments() {
        for (label, sql) in everySchemaQuery {
            XCTAssertFalse(sql.contains("ALL_SEGMENTS"), "\(label) names ALL_SEGMENTS, which does not exist")
        }
    }
}
