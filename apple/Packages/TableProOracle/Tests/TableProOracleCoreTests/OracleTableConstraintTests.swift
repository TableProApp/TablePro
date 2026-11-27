import Foundation
@testable import TableProOracleCore
import Testing

// An Oracle dump wrote no PRIMARY KEY, UNIQUE or CHECK constraint, so every foreign key it added later failed with
// ORA-02270. Rows are in the column order of `OracleSchemaQueries.tableConstraints`.
struct OracleTableConstraintTests {
    private func row(
        _ name: String,
        _ type: String,
        column: String?,
        deferrable: String = "NOT DEFERRABLE",
        deferred: String = "IMMEDIATE",
        status: String = "ENABLED",
        generated: String = "USER NAME",
        condition: String? = nil,
        validated: String = "VALIDATED"
    ) -> [OracleRawCell] {
        [
            .string(name), .string(type), .string(deferrable), .string(deferred), .string(status), .string(generated),
            condition.map(OracleRawCell.string) ?? .null,
            column.map(OracleRawCell.string) ?? .null,
            .string(validated)
        ]
    }

    // Rows that break a NOVALIDATE constraint are in the source, so it goes in disabled and is enabled after them.
    @Test func testANovalidateConstraintIsWrittenDisabledAndEnabledAfterTheRows() {
        let constraints = OracleSchemaQueries.parseTableConstraints([
            row("PK_LOG", "P", column: "ID", validated: "NOT VALIDATED"),
            row("SYS_C0042", "U", column: "CODE", generated: "GENERATED NAME", validated: "NOT VALIDATED"),
            row("UQ_REF", "U", column: "REF")
        ])
        let quote = OracleSchemaQueries.quoteIdentifier

        #expect(constraints.map { $0.clause(quote: quote) } == [
            "CONSTRAINT \"PK_LOG\" PRIMARY KEY (\"ID\") DISABLE",
            "UNIQUE (\"CODE\") DISABLE",
            "CONSTRAINT \"UQ_REF\" UNIQUE (\"REF\")"
        ])
        #expect(constraints.compactMap { $0.enableAfterRowsStatement(qualifiedTable: "\"S\".\"LOG\"", quote: quote) } == [
            "ALTER TABLE \"S\".\"LOG\" ENABLE NOVALIDATE CONSTRAINT \"PK_LOG\"",
            "ALTER TABLE \"S\".\"LOG\" ENABLE NOVALIDATE UNIQUE (\"CODE\")"
        ])
    }

    @Test func testOnlyAValidatedNotNullCheckCountsAsRestated() {
        let constraints = OracleSchemaQueries.parseTableConstraints([
            row("NN_ID", "C", column: "ID", condition: "\"ID\" IS NOT NULL"),
            row("NN_ID2", "C", column: "ID", condition: "\"ID\" IS NOT NULL", validated: "NOT VALIDATED")
        ])
        #expect(constraints.map { $0.restatesNotNull(of: ["ID"]) } == [true, false])
    }

    // A generated name was not written, so a key is enabled by what it is and a check is added after the rows.
    @Test func testAGeneratedNameNovalidateConstraintNeedsNoName() {
        let constraints = OracleSchemaQueries.parseTableConstraints([
            row("SYS_C0001", "P", column: "ID", generated: "GENERATED NAME", validated: "NOT VALIDATED"),
            row("SYS_C0002", "C", column: "QTY", generated: "GENERATED NAME", condition: "qty > 0", validated: "NOT VALIDATED")
        ])
        let quote = OracleSchemaQueries.quoteIdentifier

        #expect(constraints.map { $0.isAddedAfterRows } == [false, true])
        #expect(constraints.compactMap { $0.enableAfterRowsStatement(qualifiedTable: "T", quote: quote) }
            == ["ALTER TABLE T ENABLE NOVALIDATE PRIMARY KEY"])
    }

    @Test func testRowsGroupIntoConstraintsKeysFirst() {
        let constraints = OracleSchemaQueries.parseTableConstraints([
            row("CK_QTY", "C", column: "QTY", condition: "qty > 0"),
            row("PK_ORDERS", "P", column: "TENANT"),
            row("PK_ORDERS", "P", column: "ID"),
            row("UQ_CODE", "U", column: "CODE")
        ])

        let names = constraints.map(\.name)
        #expect(names == ["PK_ORDERS", "UQ_CODE", "CK_QTY"])
        #expect(constraints.first?.columns == ["TENANT", "ID"])
        #expect(constraints.last?.condition == "qty > 0")
    }

    @Test func testAKeyIsWrittenAsAConstraintOnItsColumns() throws {
        let constraints = OracleSchemaQueries.parseTableConstraints([
            row("PK_ORDERS", "P", column: "TENANT"),
            row("PK_ORDERS", "P", column: "ID"),
            row("UQ_CODE", "U", column: "CODE")
        ])

        #expect(constraints.map { $0.clause(quote: OracleSchemaQueries.quoteIdentifier) } == [
            "CONSTRAINT \"PK_ORDERS\" PRIMARY KEY (\"TENANT\", \"ID\")",
            "CONSTRAINT \"UQ_CODE\" UNIQUE (\"CODE\")"
        ])
    }

    @Test func testAGeneratedNameIsLeftForTheServer() throws {
        let constraint = try #require(OracleSchemaQueries.parseTableConstraints([
            row("SYS_C008123", "P", column: "ID", generated: "GENERATED NAME")
        ]).first)

        #expect(constraint.clause(quote: OracleSchemaQueries.quoteIdentifier) == "PRIMARY KEY (\"ID\")")
    }

    @Test func testDeferralAndADisabledStateAreKept() {
        let constraints = OracleSchemaQueries.parseTableConstraints([
            row("UQ_A", "U", column: "A", deferrable: "DEFERRABLE", deferred: "DEFERRED"),
            row("UQ_B", "U", column: "B", deferrable: "DEFERRABLE"),
            row("UQ_C", "U", column: "C", status: "DISABLED")
        ])

        #expect(constraints.map { $0.clause(quote: OracleSchemaQueries.quoteIdentifier) } == [
            "CONSTRAINT \"UQ_A\" UNIQUE (\"A\") DEFERRABLE INITIALLY DEFERRED",
            "CONSTRAINT \"UQ_B\" UNIQUE (\"B\") DEFERRABLE",
            "CONSTRAINT \"UQ_C\" UNIQUE (\"C\") DISABLE"
        ])
    }

    @Test func testACheckKeepsItsConditionAsTheCatalogStoresIt() throws {
        let constraint = try #require(OracleSchemaQueries.parseTableConstraints([
            row("CK_STATUS", "C", column: "STATUS", condition: "status IN ('A', 'B')\n")
        ]).first)

        #expect(constraint.clause(quote: OracleSchemaQueries.quoteIdentifier) == "CONSTRAINT \"CK_STATUS\" CHECK (status IN ('A', 'B'))")
    }

    @Test func testTheNotNullCheckOfANotNullColumnIsTheColumnsOwn() throws {
        let constraints = OracleSchemaQueries.parseTableConstraints([
            row("SYS_C0081", "C", column: "ID", generated: "GENERATED NAME", condition: "\"ID\" IS NOT NULL"),
            row("NN_NAME", "C", column: "Na\"me", condition: "\"Na\"\"me\" IS NOT NULL"),
            row("CK_NOTE", "C", column: "NOTE", condition: "\"NOTE\" IS NOT NULL"),
            row("CK_QTY", "C", column: "QTY", condition: "QTY > 0")
        ])

        let restated = constraints.filter { $0.restatesNotNull(of: ["ID", "Na\"me", "QTY"]) }.map(\.name)
        #expect(restated == ["NN_NAME", "SYS_C0081"])
    }

    @Test func testAKeyNeverRestatesANotNull() throws {
        let constraint = try #require(OracleSchemaQueries.parseTableConstraints([row("PK_T", "P", column: "ID")]).first)

        #expect(!constraint.restatesNotNull(of: ["ID"]))
    }

    @Test func testOtherConstraintTypesAreLeftOut() {
        let constraints = OracleSchemaQueries.parseTableConstraints([
            row("FK_T", "R", column: "PARENT_ID"),
            row("V_T", "V", column: nil)
        ])

        #expect(constraints.isEmpty)
    }

    // 11g has no `SEARCH_CONDITION_VC`, and 12.1 and later cut it at 4,000 bytes: an 11g dump left every check out.
    @Test func testTheQueryReadsChecksWholeFromTheLongColumn() {
        let sql = OracleSchemaQueries.tableConstraints(schema: "HR", table: "ORDERS")

        #expect(sql.contains("c.GENERATED,\n       c.SEARCH_CONDITION, cc.COLUMN_NAME, c.VALIDATED"))
        #expect(!sql.contains("SEARCH_CONDITION_VC"))
        #expect(sql.contains("c.CONSTRAINT_TYPE IN ('P', 'U', 'C')"))
    }

    @Test func testTheQueryEscapesTheOwnerAndTable() {
        let sql = OracleSchemaQueries.tableConstraints(schema: "O'BRIEN", table: "IT'S")

        #expect(sql.contains("c.OWNER = 'O''BRIEN'"))
        #expect(sql.contains("c.TABLE_NAME = 'IT''S'"))
    }

    @Test func testBooleanLiteralsArriveWith23ai() {
        #expect(!OracleServerRelease(major: 21).hasBooleanType)
        #expect(OracleServerRelease(major: 23).hasBooleanType)
    }
}
