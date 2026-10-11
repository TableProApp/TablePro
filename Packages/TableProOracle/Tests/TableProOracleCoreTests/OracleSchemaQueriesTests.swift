@testable import TableProOracleCore
import XCTest

final class OracleSchemaQueriesTests: XCTestCase {
    private let release23ai = OracleServerRelease(major: 23, update: 4)

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
        XCTAssertEqual(parsed?.dataType, "NUMBER")
        XCTAssertEqual(parsed?.isNullable, false)
        XCTAssertEqual(parsed?.isPrimaryKey, false)
        XCTAssertEqual(parsed?.displayType, "NUMBER(10,2)")
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

    /// Position 12 is `GENERATION_TYPE` from `ALL_TAB_IDENTITY_COLS`, which only an identity column has.
    func testParseColumnRowReadsHowAnIdentityIsGeneratedAndWhetherAColumnIsVirtual() {
        let always: [OracleRawCell] = [
            .string("ID"), .string("NUMBER"), .string("22"), .null, .null, .string("N"), .string("Y"),
            .string("\"HR\".\"ISEQ$$_1\".nextval"), .string("NO"), .string("YES"), .string("NO"), .string("NO"),
            .string("ALWAYS")
        ]
        XCTAssertEqual(OracleSchemaQueries.parseColumnRow(always)?.identityGeneration, .always)
        XCTAssertEqual(OracleSchemaQueries.parseColumnRow(always)?.isVirtual, false)

        let byDefault: [OracleRawCell] = [
            .string("ID"), .string("NUMBER"), .string("22"), .null, .null, .string("N"), .string("Y"),
            .string("\"HR\".\"ISEQ$$_2\".nextval"), .string("NO"), .string("YES"), .string("NO"), .string("NO"),
            .string("BY DEFAULT")
        ]
        XCTAssertEqual(OracleSchemaQueries.parseColumnRow(byDefault)?.identityGeneration, .byDefault)

        let virtual: [OracleRawCell] = [
            .string("V"), .string("NUMBER"), .string("22"), .null, .null, .string("Y"), .string("N"),
            .string("LENGTH(\"NAME\")"), .string("YES"), .string("NO"), .string("NO"), .string("NO"), .null
        ]
        XCTAssertNil(OracleSchemaQueries.parseColumnRow(virtual)?.identityGeneration)
        XCTAssertEqual(OracleSchemaQueries.parseColumnRow(virtual)?.isVirtual, true)
    }

    func testColumnsQueryReadsTheIdentityGenerationOnlyWhereTheReleaseHasIdentity() {
        let modern = OracleSchemaQueries.columns(schema: "HR", table: "T", release: OracleServerRelease(major: 23))
        XCTAssertTrue(modern.contains("i.GENERATION_TYPE FROM SYS.ALL_TAB_IDENTITY_COLS i"))
        let legacy = OracleSchemaQueries.columns(schema: "HR", table: "T", release: OracleServerRelease(major: 11))
        XCTAssertTrue(legacy.contains("NULL AS GENERATION_TYPE"))
        XCTAssertFalse(legacy.contains("ALL_TAB_IDENTITY_COLS"))
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
        XCTAssertEqual(parsed?.column.displayType, "NUMBER(5)")
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
    /// per-table one, column for column, and the parser reads by position, so every release projects the same count.
    func testTheBulkReadProjectsTheTableNameThenThePerTableColumns() {
        for release in Self.releases {
            let single = projection(of: OracleSchemaQueries.columns(schema: "HR", table: "T", release: release))
            let bulk = projection(of: OracleSchemaQueries.allColumns(schema: "HR", release: release))
            XCTAssertEqual(bulk.first, "c.TABLE_NAME")
            XCTAssertEqual(Array(bulk.dropFirst()), single, "release \(release)")
            XCTAssertEqual(single.count, 19, "release \(release)")
            XCTAssertEqual(single.last, "c.OWNER", "release \(release)")
        }
    }

    private static let releases = [
        OracleServerRelease(major: 11),
        OracleServerRelease(major: 12),
        OracleServerRelease(major: 19),
        OracleServerRelease(major: 21),
        OracleServerRelease(major: 23, update: 3),
        OracleServerRelease(major: 23, update: 4),
        OracleServerRelease(major: 23, update: 26)
    ]

    /// The `ALL_TAB_COLS` columns each release lacks, from the Database Reference of 11.2, 12.1, 19c, 21c and 23ai.
    /// `VECTOR_INFO` is not documented before 23.4, so 23.3 is treated as lacking it.
    func testNoReleaseIsAskedForATypeColumnItDoesNotHave() {
        let lacking: [(OracleServerRelease, [String])] = [
            (OracleServerRelease(major: 11), ["IDENTITY_COLUMN", "DEFAULT_ON_NULL", "DEFAULT_ON_NULL_UPD", "USER_GENERATED", "VECTOR_INFO"]),
            (OracleServerRelease(major: 12), ["DEFAULT_ON_NULL_UPD", "VECTOR_INFO"]),
            (OracleServerRelease(major: 21), ["DEFAULT_ON_NULL_UPD", "VECTOR_INFO"]),
            (OracleServerRelease(major: 23, update: 3), ["VECTOR_INFO"]),
            (OracleServerRelease(major: 23, update: 4), [])
        ]
        for (release, columns) in lacking {
            for sql in [
                OracleSchemaQueries.columns(schema: "HR", table: "T", release: release),
                OracleSchemaQueries.allColumns(schema: "HR", release: release)
            ] {
                for column in columns {
                    XCTAssertFalse(names(sql, column), "release \(release) names \(column)")
                }
                for column in ["CHAR_LENGTH", "CHAR_USED", "DATA_TYPE_OWNER", "DATA_TYPE_MOD"] {
                    XCTAssertTrue(names(sql, column), "release \(release) does not name \(column)")
                }
            }
        }
    }

    func testVectorInfoIsALiteralNullWhereTheReleaseLacksIt() {
        let legacy = OracleSchemaQueries.columns(schema: "HR", table: "T", release: OracleServerRelease(major: 23, update: 3))
        XCTAssertTrue(legacy.contains("NULL AS VECTOR_INFO"), legacy)
        let modern = OracleSchemaQueries.columns(schema: "HR", table: "T", release: release23ai)
        XCTAssertTrue(modern.contains("c.VECTOR_INFO AS VECTOR_INFO"), modern)
    }

    private func names(_ sql: String, _ column: String) -> Bool {
        sql.range(of: #"\bc\.\#(column)\b"#, options: .regularExpression) != nil
    }

    private func projection(of sql: String) -> [String] {
        guard let select = sql.range(of: "SELECT"),
              let from = sql.range(of: "FROM \(OracleDictionary.allTabCols) c") else { return [] }
        return sql[select.upperBound..<from.lowerBound]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// A whole row as the projection writes it, positions 13 to 18 being `CHAR_LENGTH`, `CHAR_USED`,
    /// `DATA_TYPE_OWNER`, `DATA_TYPE_MOD`, `VECTOR_INFO` and the table's `OWNER`.
    private func columnRow(
        _ name: String,
        type: String,
        length: String?,
        precision: String? = nil,
        scale: String? = nil,
        storedDefault: String? = nil,
        isVirtual: Bool = false,
        charLength: String? = nil,
        charUsed: String? = nil,
        typeOwner: String? = nil,
        typeModifier: String? = nil,
        vectorInfo: String? = nil
    ) -> [OracleRawCell] {
        let cell: (String?) -> OracleRawCell = { $0.map(OracleRawCell.string) ?? .null }
        return [
            .string(name), .string(type), cell(length), cell(precision), cell(scale), .string("Y"), .string("N"),
            cell(storedDefault), .string(isVirtual ? "YES" : "NO"), .string("NO"), .string("NO"), .string("NO"), .null,
            cell(charLength), cell(charUsed), cell(typeOwner), cell(typeModifier), cell(vectorInfo), .string("HR")
        ]
    }

    /// `NVARCHAR2(100)` reports `DATA_LENGTH` 200 in AL16UTF16, which the app used to show as `nvarchar2(200)`.
    func testParseColumnRowReadsTheCharacterLengthAndSemantics() {
        let national = OracleSchemaQueries.parseColumnRow(
            columnRow("NOTE", type: "NVARCHAR2", length: "200", charLength: "100", charUsed: "C")
        )
        XCTAssertEqual(national?.displayType, "NVARCHAR2(100)")
        XCTAssertEqual(national?.charLength, 100)
        XCTAssertNil(national?.classificationTypeName)

        let characters = OracleSchemaQueries.parseColumnRow(
            columnRow("NAME", type: "VARCHAR2", length: "200", charLength: "50", charUsed: "C")
        )
        XCTAssertEqual(characters?.displayType, "VARCHAR2(50 CHAR)")
        XCTAssertEqual(characters?.dataLength, "200")
    }

    func testParseColumnRowQualifiesATypeFromAnotherSchema() {
        let geometry = OracleSchemaQueries.parseColumnRow(
            columnRow("SHAPE", type: "SDO_GEOMETRY", length: "1", typeOwner: "MDSYS")
        )
        XCTAssertEqual(geometry?.displayType, "\"MDSYS\".\"SDO_GEOMETRY\"")
        XCTAssertEqual(geometry?.classificationTypeName, "SDO_GEOMETRY")

        let reference = OracleSchemaQueries.parseColumnRow(
            columnRow("ADDR", type: "ADDRESS_T", length: "50", typeOwner: "HR", typeModifier: "REF")
        )
        XCTAssertEqual(reference?.displayType, "REF ADDRESS_T")
        XCTAssertEqual(reference?.classificationTypeName, "ADDRESS_T")
    }

    func testParseColumnRowKeepsTheCaseOfAQuotedTypeName() {
        let mixed = OracleSchemaQueries.parseColumnRow(
            columnRow("M", type: "Mixed_T", length: "1", typeOwner: "HR")
        )
        XCTAssertEqual(mixed?.dataType, "Mixed_T")
        XCTAssertEqual(mixed?.displayType, "\"Mixed_T\"")
    }

    func testParseColumnRowReadsVectorInfo() {
        let vector = OracleSchemaQueries.parseColumnRow(
            columnRow("EMBEDDING", type: "VECTOR", length: "8200", charLength: "3", vectorInfo: "VECTOR(3,FLOAT32,DENSE)")
        )
        XCTAssertEqual(vector?.displayType, "VECTOR(3, FLOAT32)")
        XCTAssertNil(vector?.charLength)
    }

    /// Oracle stores a virtual column's expression rewritten, `"A"+1` for `a + 1`, in `DATA_DEFAULT` (measured).
    func testParseColumnRowReadsTheExpressionOfAVirtualColumn() {
        let virtual = OracleSchemaQueries.parseColumnRow(
            columnRow("V", type: "NUMBER", length: "22", storedDefault: "\"A\"+1\n  ", isVirtual: true)
        )
        XCTAssertEqual(virtual?.generationExpression, "\"A\"+1")
        XCTAssertNil(virtual?.defaultValue)

        let plain = OracleSchemaQueries.parseColumnRow(
            columnRow("D", type: "NUMBER", length: "22", storedDefault: "5 /* five */")
        )
        XCTAssertNil(plain?.generationExpression)
        XCTAssertEqual(plain?.defaultValue, "5")
    }

    func testParseColumnRowClassifiesADateAsATimestamp() {
        let date = OracleSchemaQueries.parseColumnRow(columnRow("CREATED", type: "DATE", length: "7"))
        XCTAssertEqual(date?.displayType, "DATE")
        XCTAssertEqual(date?.classificationTypeName, "TIMESTAMP(0)")
    }

    func testTheBulkRowReadsTheSameTypeColumns() {
        let row = [OracleRawCell.string("NOTES")]
            + columnRow("NOTE", type: "NVARCHAR2", length: "200", charLength: "100", charUsed: "C")
        XCTAssertEqual(OracleSchemaQueries.parseTableColumnRow(row)?.column.displayType, "NVARCHAR2(100)")
    }

    func testParseColumnRowTreatsMissingTypeAsVarchar2() {
        let parsed = OracleSchemaQueries.parseColumnRow([.string("C"), .null, .null, .null, .null, .string("Y"), .string("Y")])
        XCTAssertEqual(parsed?.dataType, "VARCHAR2")
        XCTAssertEqual(parsed?.isNullable, true)
        XCTAssertEqual(parsed?.isPrimaryKey, true)
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
