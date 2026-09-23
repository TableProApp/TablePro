@testable import TableProOracleCore
import XCTest

final class OracleSchemaQueriesTests: XCTestCase {
    private let release23ai = OracleServerRelease(major: 23)

    func testSchemaOwnerIsEscapedInEveryQuery() {
        let owner = "O'BRIEN"
        XCTAssertTrue(OracleSchemaQueries.tables(schema: owner).contains("owner = 'O''BRIEN'"))
        XCTAssertTrue(
            OracleSchemaQueries.columns(schema: owner, table: "T", release: release23ai).contains("c.OWNER = 'O''BRIEN'")
        )
        XCTAssertTrue(
            OracleSchemaQueries.allColumns(schema: owner, release: release23ai).contains("c.OWNER = 'O''BRIEN'")
        )
        XCTAssertTrue(OracleSchemaQueries.indexes(schema: owner, table: "T").contains("i.OWNER = 'O''BRIEN'"))
        XCTAssertTrue(OracleSchemaQueries.foreignKeys(schema: owner, table: "T").contains("ac.OWNER = 'O''BRIEN'"))
    }

    func testTableNameIsEscaped() {
        let sql = OracleSchemaQueries.columns(schema: "HR", table: "IT'S", release: release23ai)
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
        XCTAssertTrue(sql.contains("LEFT JOIN SYS.ALL_PART_TABLES pt"))
        XCTAssertTrue(sql.contains("CASE WHEN pt.table_name IS NULL THEN 'N' ELSE 'Y' END"))
        XCTAssertTrue(sql.contains("CASE WHEN pt.interval IS NULL THEN pt.partition_count END"))
    }

    /// `HIGH_VALUE` is a LONG column OracleNIO cannot decode, so it must never be selected.
    func testPartitionQueriesNeverReadHighValue() {
        let partitions = OracleSchemaQueries.partitions(schema: "HR", table: "ORDERS")
        let subpartitions = OracleSchemaQueries.subpartitions(schema: "HR", table: "ORDERS")
        XCTAssertFalse(partitions.lowercased().contains("high_value"))
        XCTAssertFalse(subpartitions.lowercased().contains("high_value"))
        XCTAssertTrue(partitions.contains("p.table_owner = 'HR'"))
        XCTAssertTrue(subpartitions.contains("s.table_name = 'ORDERS'"))
    }

    /// Every subpartition of the table in one statement, carrying its parent's name so the rows
    /// group in memory. Asking per partition was one round trip each, and one timeout among
    /// hundreds discarded the whole answer.
    func testSubpartitionsAreFetchedForTheWholeTableAtOnce() {
        let sql = OracleSchemaQueries.subpartitions(schema: "HR", table: "ORDERS")
        XCTAssertTrue(sql.contains("s.partition_name"))
        XCTAssertFalse(sql.contains("s.partition_name = '"))
        XCTAssertTrue(sql.contains("ORDER BY s.partition_name, s.subpartition_position"))
    }

    func testParseSubpartitionRowCarriesItsParentName() {
        let parsed = OracleSchemaQueries.parseSubpartitionRow([
            .string("P1"), .string("P1_SP2"), .string("2"), .string("40")
        ])
        XCTAssertEqual(parsed?.parent, "P1")
        XCTAssertEqual(parsed?.row.name, "P1_SP2")
        XCTAssertEqual(parsed?.row.position, 2)
        XCTAssertEqual(parsed?.row.rowCount, 40)
        XCTAssertEqual(parsed?.row.isSubpartitioned, false)
    }

    func testParseSubpartitionRowNeedsBothNames() {
        XCTAssertNil(OracleSchemaQueries.parseSubpartitionRow([.string("P1")]))
        XCTAssertNil(OracleSchemaQueries.parseSubpartitionRow([.null, .string("P1_SP1")]))
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

    func testParseColumnRowReadsTheDefault() {
        let row: [OracleRawCell] = [
            .string("CREATED"), .string("DATE"), .string("7"), .null, .null, .string("Y"), .string("N"),
            .string("sysdate\n  "), .string("NO"), .string("NO"), .string("NO"), .string("NO")
        ]
        XCTAssertEqual(OracleSchemaQueries.parseColumnRow(row)?.defaultValue, "sysdate")
    }

    func testParseColumnRowWithoutADefaultReadsNil() {
        let row: [OracleRawCell] = [
            .string("NOTE"), .string("VARCHAR2"), .string("20"), .null, .null, .string("Y"), .string("N"),
            .null, .string("NO"), .string("NO"), .string("NO"), .string("NO")
        ]
        XCTAssertNil(OracleSchemaQueries.parseColumnRow(row)?.defaultValue)
    }

    /// Positions 8 and 9 are `VIRTUAL_COLUMN` and `IDENTITY_COLUMN`, in the order the projection writes them.
    func testParseColumnRowDropsTheDefaultOfAnIdentityOrVirtualColumn() {
        let identity: [OracleRawCell] = [
            .string("ID"), .string("NUMBER"), .string("22"), .null, .null, .string("N"), .string("Y"),
            .string("\"HR\".\"ISEQ$$_73292\".nextval"), .string("NO"), .string("YES"), .string("NO"), .string("NO")
        ]
        XCTAssertNil(OracleSchemaQueries.parseColumnRow(identity)?.defaultValue)

        let virtual: [OracleRawCell] = [
            .string("TOTAL"), .string("NUMBER"), .string("22"), .null, .null, .string("Y"), .string("N"),
            .string("\"C_ZERO\"+1"), .string("YES"), .string("NO"), .string("NO"), .string("NO")
        ]
        XCTAssertNil(OracleSchemaQueries.parseColumnRow(virtual)?.defaultValue)
    }

    /// Positions 10 and 11 are `DEFAULT_ON_NULL` and `DEFAULT_ON_NULL_UPD`.
    func testParseColumnRowReadsDefaultOnNull() {
        let onInsert: [OracleRawCell] = [
            .string("STATUS"), .string("VARCHAR2"), .string("10"), .null, .null, .string("N"), .string("N"),
            .string("'x'"), .string("NO"), .string("NO"), .string("YES"), .string("NO")
        ]
        XCTAssertEqual(OracleSchemaQueries.parseColumnRow(onInsert)?.defaultValue, "ON NULL 'x'")

        let onUpdate: [OracleRawCell] = [
            .string("STATUS"), .string("VARCHAR2"), .string("10"), .null, .null, .string("N"), .string("N"),
            .string("'u'"), .string("NO"), .string("NO"), .string("YES"), .string("YES")
        ]
        XCTAssertEqual(
            OracleSchemaQueries.parseColumnRow(onUpdate)?.defaultValue,
            "ON NULL FOR INSERT AND UPDATE 'u'"
        )
    }

    func testParseTableColumnRowReadsTheTableThenTheSameColumnShape() {
        let row: [OracleRawCell] = [
            .string("ORDERS"), .string("QTY"), .string("NUMBER"), .string("22"), .string("5"), .string("0"),
            .string("N"), .string("N"), .string("0"), .string("NO"), .string("NO"), .string("NO"), .string("NO")
        ]
        let parsed = OracleSchemaQueries.parseTableColumnRow(row)
        XCTAssertEqual(parsed?.table, "ORDERS")
        XCTAssertEqual(parsed?.column.name, "QTY")
        XCTAssertEqual(parsed?.column.displayType, "number(5)")
        XCTAssertEqual(parsed?.column.isNullable, false)
        XCTAssertEqual(parsed?.column.defaultValue, "0")
        XCTAssertNil(OracleSchemaQueries.parseTableColumnRow([.null, .string("QTY")]))
    }

    /// 11g has no `IDENTITY_COLUMN`, `DEFAULT_ON_NULL` or `USER_GENERATED`, and naming any of them fails the statement
    /// with ORA-00904. Its `ALL_TAB_COLUMNS` is `ALL_TAB_COLS` without the hidden columns.
    func testAnElevenGServerIsNeverAskedForAColumnItDoesNotHave() {
        let release = OracleServerRelease(major: 11)
        for sql in [
            OracleSchemaQueries.columns(schema: "HR", table: "T", release: release),
            OracleSchemaQueries.allColumns(schema: "HR", release: release)
        ] {
            XCTAssertFalse(sql.contains("c.IDENTITY_COLUMN"), sql)
            XCTAssertFalse(sql.contains("c.DEFAULT_ON_NULL"), sql)
            XCTAssertFalse(sql.contains("USER_GENERATED"), sql)
            XCTAssertTrue(sql.contains("c.HIDDEN_COLUMN = 'NO'"), sql)
            XCTAssertTrue(sql.contains("'NO' AS IDENTITY_COLUMN"), sql)
            XCTAssertTrue(sql.contains("c.VIRTUAL_COLUMN"), sql)
            XCTAssertTrue(sql.contains("c.DATA_DEFAULT"), sql)
        }
    }

    /// From 12.1 `ALL_TAB_COLUMNS` is `ALL_TAB_COLS` where `USER_GENERATED = 'YES'`, which keeps invisible columns;
    /// filtering on `HIDDEN_COLUMN` there would drop them.
    func testATwelveCServerReadsTheFlagsAndKeepsInvisibleColumns() {
        let release = OracleServerRelease(major: 19)
        for sql in [
            OracleSchemaQueries.columns(schema: "HR", table: "T", release: release),
            OracleSchemaQueries.allColumns(schema: "HR", release: release)
        ] {
            XCTAssertTrue(sql.contains("c.USER_GENERATED = 'YES'"), sql)
            XCTAssertFalse(sql.contains("HIDDEN_COLUMN"), sql)
            XCTAssertTrue(sql.contains("c.IDENTITY_COLUMN AS IDENTITY_COLUMN"), sql)
            XCTAssertTrue(sql.contains("c.DEFAULT_ON_NULL AS DEFAULT_ON_NULL"), sql)
            XCTAssertTrue(sql.contains("'NO' AS DEFAULT_ON_NULL_UPD"), sql)
            XCTAssertFalse(sql.contains("c.DEFAULT_ON_NULL_UPD"), sql)
        }
    }

    func testA23aiServerReadsDefaultOnNullForUpdate() {
        for sql in [
            OracleSchemaQueries.columns(schema: "HR", table: "T", release: release23ai),
            OracleSchemaQueries.allColumns(schema: "HR", release: release23ai)
        ] {
            XCTAssertTrue(sql.contains("c.DEFAULT_ON_NULL_UPD AS DEFAULT_ON_NULL_UPD"), sql)
        }
    }

    /// The bulk read is parsed by dropping its first cell, so after `TABLE_NAME` its projection has to be the
    /// per-table one, column for column.
    func testTheBulkReadProjectsTheTableNameThenThePerTableColumns() {
        for major in [11, 19, 23] {
            let release = OracleServerRelease(major: major)
            let single = projection(of: OracleSchemaQueries.columns(schema: "HR", table: "T", release: release))
            let bulk = projection(of: OracleSchemaQueries.allColumns(schema: "HR", release: release))
            XCTAssertEqual(bulk.first, "c.TABLE_NAME")
            XCTAssertEqual(Array(bulk.dropFirst()), single, "release \(major)")
            XCTAssertEqual(single.count, 12, "release \(major)")
        }
    }

    private func projection(of sql: String) -> [String] {
        guard let select = sql.range(of: "SELECT"), let from = sql.range(of: "FROM ") else { return [] }
        return sql[select.upperBound..<from.lowerBound]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
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
