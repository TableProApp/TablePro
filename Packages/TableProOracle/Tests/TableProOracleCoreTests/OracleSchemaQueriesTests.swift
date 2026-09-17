@testable import TableProOracleCore
import XCTest

final class OracleSchemaQueriesTests: XCTestCase {
    func testSchemaOwnerIsEscapedInEveryQuery() {
        let owner = "O'BRIEN"
        XCTAssertTrue(OracleSchemaQueries.tables(schema: owner).contains("owner = 'O''BRIEN'"))
        XCTAssertTrue(OracleSchemaQueries.columns(schema: owner, table: "T").contains("c.OWNER = 'O''BRIEN'"))
        XCTAssertTrue(OracleSchemaQueries.indexes(schema: owner, table: "T").contains("i.OWNER = 'O''BRIEN'"))
        XCTAssertTrue(OracleSchemaQueries.foreignKeys(schema: owner, table: "T").contains("ac.OWNER = 'O''BRIEN'"))
    }

    func testTableNameIsEscaped() {
        let sql = OracleSchemaQueries.columns(schema: "HR", table: "IT'S")
        XCTAssertTrue(sql.contains("c.TABLE_NAME = 'IT''S'"))
        XCTAssertFalse(sql.contains("'IT'S'"))
    }

    func testSetCurrentSchemaQuotesAndEscapesIdentifier() {
        XCTAssertEqual(
            OracleSchemaQueries.setCurrentSchema("HR"),
            "ALTER SESSION SET CURRENT_SCHEMA = \"HR\""
        )
        XCTAssertEqual(
            OracleSchemaQueries.setCurrentSchema("WEIRD\"NAME"),
            "ALTER SESSION SET CURRENT_SCHEMA = \"WEIRD\"\"NAME\""
        )
    }

    func testParseTableRowDistinguishesViews() {
        let table = OracleSchemaQueries.parseTableRow([.string("EMPLOYEES"), .string("BASE TABLE")])
        XCTAssertEqual(table, OracleTableRow(name: "EMPLOYEES", isView: false))

        let view = OracleSchemaQueries.parseTableRow([.string("EMP_VIEW"), .string("VIEW")])
        XCTAssertEqual(view, OracleTableRow(name: "EMP_VIEW", isView: true))
    }

    func testParseTableRowReadsPartitioningSeparatelyFromTheCount() {
        let counted = OracleSchemaQueries.parseTableRow([
            .string("ORDERS"), .string("BASE TABLE"), .string("Y"), .string("12")
        ])
        XCTAssertEqual(counted, OracleTableRow(name: "ORDERS", isView: false, isPartitioned: true, partitionCount: 12))

        let plain = OracleSchemaQueries.parseTableRow([
            .string("EMPLOYEES"), .string("BASE TABLE"), .string("N"), .null
        ])
        XCTAssertEqual(plain, OracleTableRow(name: "EMPLOYEES", isView: false))
    }

    /// An interval-partitioned table reports a count that means the range the server will extend
    /// into rather than the partitions it holds, so the query omits it. The table is still
    /// partitioned, and reading the missing count as "not partitioned" would hide its partitions.
    func testIntervalPartitionedTableStaysPartitionedWithoutACount() {
        let interval = OracleSchemaQueries.parseTableRow([
            .string("EVENTS"), .string("BASE TABLE"), .string("Y"), .null
        ])
        XCTAssertEqual(interval?.isPartitioned, true)
        XCTAssertNil(interval?.partitionCount)
    }

    func testTableListingReadsPartitioningFromAllPartTables() {
        let sql = OracleSchemaQueries.tables(schema: "HR")
        XCTAssertTrue(sql.contains("LEFT JOIN all_part_tables pt"))
        XCTAssertTrue(sql.contains("CASE WHEN pt.table_name IS NULL THEN 'N' ELSE 'Y' END"))
        XCTAssertTrue(sql.contains("CASE WHEN pt.interval IS NULL THEN pt.partition_count END"))
    }

    /// `HIGH_VALUE` is a LONG column OracleNIO cannot decode, so it must never be selected.
    func testPartitionQueriesNeverReadHighValue() {
        let partitions = OracleSchemaQueries.partitions(schema: "HR", table: "ORDERS")
        let subpartitions = OracleSchemaQueries.subpartitions(schema: "HR", table: "ORDERS", partition: "P1")
        XCTAssertFalse(partitions.lowercased().contains("high_value"))
        XCTAssertFalse(subpartitions.lowercased().contains("high_value"))
        XCTAssertTrue(partitions.contains("p.table_owner = 'HR'"))
        XCTAssertTrue(subpartitions.contains("s.partition_name = 'P1'"))
    }

    func testParsePartitionRowReadsSubpartitionCount() {
        let composite = OracleSchemaQueries.parsePartitionRow([
            .string("P1"), .string("2"), .string("500"), .string("4")
        ])
        XCTAssertEqual(composite?.isSubpartitioned, true)
        XCTAssertEqual(composite?.position, 2)
        XCTAssertEqual(composite?.rowCount, 500)

        let leaf = OracleSchemaQueries.parsePartitionRow([
            .string("P2"), .string("3"), .null, .string("0")
        ])
        XCTAssertEqual(leaf?.isSubpartitioned, false)
        XCTAssertNil(leaf?.rowCount)
    }

    func testParseTableRowReturnsNilWithoutAName() {
        XCTAssertNil(OracleSchemaQueries.parseTableRow([.null, .string("VIEW")]))
        XCTAssertNil(OracleSchemaQueries.parseTableRow([]))
    }

    func testParseColumnRowReadsFlagsAndNullPrimaryKeyJoin() {
        let row: [OracleRawCell] = [
            .string("SALARY"), .string("NUMBER"), .string("22"), .string("10"), .string("2"),
            .string("N"), .string("N")
        ]
        let parsed = OracleSchemaQueries.parseColumnRow(row)
        XCTAssertEqual(parsed?.name, "SALARY")
        XCTAssertEqual(parsed?.dataType, "number")
        XCTAssertEqual(parsed?.isNullable, false)
        XCTAssertEqual(parsed?.isPrimaryKey, false)
        XCTAssertEqual(parsed?.displayType, "number(10,2)")
    }

    func testParseColumnRowTreatsMissingTypeAsVarchar2() {
        let parsed = OracleSchemaQueries.parseColumnRow([.string("C"), .null, .null, .null, .null, .string("Y"), .string("Y")])
        XCTAssertEqual(parsed?.dataType, "varchar2")
        XCTAssertEqual(parsed?.isNullable, true)
        XCTAssertEqual(parsed?.isPrimaryKey, true)
    }

    func testFullTypeRendersLengthPrecisionAndFixedTypes() {
        XCTAssertEqual(OracleSchemaQueries.fullType(dataType: "date", dataLength: "7", precision: nil, scale: nil), "date")
        XCTAssertEqual(OracleSchemaQueries.fullType(dataType: "clob", dataLength: "4000", precision: nil, scale: nil), "clob")
        XCTAssertEqual(OracleSchemaQueries.fullType(dataType: "varchar2", dataLength: "50", precision: nil, scale: nil), "varchar2(50)")
        XCTAssertEqual(OracleSchemaQueries.fullType(dataType: "number", dataLength: "22", precision: "10", scale: "0"), "number(10)")
        XCTAssertEqual(OracleSchemaQueries.fullType(dataType: "number", dataLength: "22", precision: "10", scale: "2"), "number(10,2)")
        XCTAssertEqual(OracleSchemaQueries.fullType(dataType: "number", dataLength: "22", precision: nil, scale: nil), "number")
        XCTAssertEqual(OracleSchemaQueries.fullType(dataType: "varchar2", dataLength: "0", precision: nil, scale: nil), "varchar2")
    }

    func testParseIndexRowReadsUniquenessAndPrimaryFlag() {
        let row: [OracleRawCell] = [.string("PK_EMP"), .string("UNIQUE"), .string("EMP_ID"), .string("Y")]
        XCTAssertEqual(
            OracleSchemaQueries.parseIndexRow(row),
            OracleIndexRow(name: "PK_EMP", isUnique: true, columnName: "EMP_ID", isPrimary: true)
        )

        let nonUnique: [OracleRawCell] = [.string("IX_DEPT"), .string("NONUNIQUE"), .string("DEPT_ID"), .string("N")]
        XCTAssertEqual(
            OracleSchemaQueries.parseIndexRow(nonUnique),
            OracleIndexRow(name: "IX_DEPT", isUnique: false, columnName: "DEPT_ID", isPrimary: false)
        )
    }

    func testParseIndexRowReturnsNilWithoutAColumn() {
        XCTAssertNil(OracleSchemaQueries.parseIndexRow([.string("IX"), .string("UNIQUE"), .null, .string("N")]))
    }

    func testParseForeignKeyRowReadsReferenceAndDeleteRule() {
        let row: [OracleRawCell] = [
            .string("FK_EMP_DEPT"), .string("DEPT_ID"), .string("DEPARTMENTS"), .string("ID"),
            .string("CASCADE"), .string("HR")
        ]
        XCTAssertEqual(
            OracleSchemaQueries.parseForeignKeyRow(row),
            OracleForeignKeyRow(
                constraintName: "FK_EMP_DEPT",
                columnName: "DEPT_ID",
                referencedTable: "DEPARTMENTS",
                referencedColumn: "ID",
                referencedSchema: "HR",
                deleteRule: "CASCADE"
            )
        )
    }

    func testParseForeignKeyRowDefaultsDeleteRule() {
        let row: [OracleRawCell] = [
            .string("FK"), .string("C"), .string("T"), .string("ID"), .null, .null
        ]
        XCTAssertEqual(OracleSchemaQueries.parseForeignKeyRow(row)?.deleteRule, "NO ACTION")
        XCTAssertNil(OracleSchemaQueries.parseForeignKeyRow(row)?.referencedSchema)
    }
}
