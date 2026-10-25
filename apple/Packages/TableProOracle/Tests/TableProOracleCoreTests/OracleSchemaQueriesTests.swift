import Foundation
@testable import TableProOracleCore
import Testing

struct OracleSchemaQueriesTests {
    private let release23ai = OracleServerRelease(major: 23, update: 4)

    @Test func testSchemaOwnerIsEscapedInEveryQuery() {
        let owner = "O'BRIEN"
        #expect(OracleSchemaQueries.tables(schema: owner).contains("owner = 'O''BRIEN'"))
        #expect(OracleSchemaQueries.columns(schema: owner, table: "T", release: release23ai).contains("c.OWNER = 'O''BRIEN'"))
        #expect(OracleSchemaQueries.allColumns(schema: owner, release: release23ai).contains("c.OWNER = 'O''BRIEN'"))
        #expect(OracleSchemaQueries.indexes(schema: owner, table: "T").contains("i.OWNER = 'O''BRIEN'"))
        #expect(OracleSchemaQueries.foreignKeys(schema: owner, table: "T").contains("ac.OWNER = 'O''BRIEN'"))
    }

    @Test func testQuoteFollowedByACombiningMarkIsEscaped() {
        let owner = "O'\u{301} OR 1=1 --"
        #expect(OracleSchemaQueries.escapeLiteral(owner) == "O''\u{301} OR 1=1 --")
        #expect(OracleSchemaQueries.quoteIdentifier("A\"\u{301}") == "\"A\"\"\u{301}\"")
    }

    @Test func testSchemaSetListingNamesEveryOwnerAndProjectsIt() throws {
        let statements = OracleSchemaQueries.tables(inSchemas: ["HR", "O'BRIEN"])
        let sql = try #require(statements.first)
        #expect(statements.count == 1)
        #expect(sql.contains("WHERE t.owner IN ('HR', 'O''BRIEN')"))
        #expect(sql.contains("FROM SYS.ALL_VIEWS WHERE owner IN ('HR', 'O''BRIEN')"))
        #expect(sql.contains("SELECT view_name, 'VIEW', 'N', NULL, owner"))
        #expect(sql.contains("ORDER BY 5, 1"))
    }

    @Test func testSchemaSetListingSplitsPastTheInListLimit() {
        let owners = (0..<2_001).map { "U\($0)" }
        let statements = OracleSchemaQueries.tables(inSchemas: owners)
        #expect(statements.count == 3)
        #expect(statements[0].contains("'U999')") && !statements[0].contains("'U1000'"))
        #expect(statements[1].contains("IN ('U1000', ") && statements[1].contains("'U1999')"))
        #expect(statements[2].contains("IN ('U2000')"))
        #expect(OracleSchemaQueries.tables(inSchemas: []).isEmpty)
    }

    @Test func testParseTableRowReadsTheOwnerOfASchemaSetRow() {
        let row = OracleSchemaQueries.parseTableRow([
            .string("ORDERS"), .string("BASE TABLE"), .string("N"), .null, .string("SALES")
        ])
        #expect(row == OracleTableRow(name: "ORDERS", isView: false, schema: "SALES"))
        #expect(OracleSchemaQueries.parseTableRow([.string("ORDERS"), .string("BASE TABLE")])?.schema == nil)
    }

    @Test func testTableNameIsEscaped() {
        let sql = OracleSchemaQueries.columns(schema: "HR", table: "IT'S", release: release23ai)
        #expect(sql.contains("c.TABLE_NAME = 'IT''S'"))
        #expect(!sql.contains("'IT'S'"))
    }

    @Test func testSetCurrentSchemaQuotesAndEscapesIdentifier() {
        #expect(OracleSchemaQueries.setCurrentSchema("HR") == "ALTER SESSION SET CURRENT_SCHEMA = \"HR\"")
        #expect(OracleSchemaQueries.setCurrentSchema("WEIRD\"NAME") == "ALTER SESSION SET CURRENT_SCHEMA = \"WEIRD\"\"NAME\"")
    }

    @Test func testParseTableRowDistinguishesViews() {
        let table = OracleSchemaQueries.parseTableRow([.string("EMPLOYEES"), .string("BASE TABLE")])
        #expect(table == OracleTableRow(name: "EMPLOYEES", isView: false))

        let view = OracleSchemaQueries.parseTableRow([.string("EMP_VIEW"), .string("VIEW")])
        #expect(view == OracleTableRow(name: "EMP_VIEW", isView: true))
    }

    @Test func testParseTableRowReadsPartitioningSeparatelyFromTheCount() {
        let counted = OracleSchemaQueries.parseTableRow([
            .string("ORDERS"), .string("BASE TABLE"), .string("Y"), .string("12")
        ])
        #expect(counted == OracleTableRow(name: "ORDERS", isView: false, isPartitioned: true, partitionCount: 12))

        let plain = OracleSchemaQueries.parseTableRow([
            .string("EMPLOYEES"), .string("BASE TABLE"), .string("N"), .null
        ])
        #expect(plain == OracleTableRow(name: "EMPLOYEES", isView: false))
    }

    /// An interval-partitioned table reports a count that means the range the server will extend
    /// into rather than the partitions it holds, so the query omits it. The table is still
    /// partitioned, and reading the missing count as "not partitioned" would hide its partitions.
    @Test func testIntervalPartitionedTableStaysPartitionedWithoutACount() {
        let interval = OracleSchemaQueries.parseTableRow([
            .string("EVENTS"), .string("BASE TABLE"), .string("Y"), .null
        ])
        #expect(interval?.isPartitioned == true)
        #expect(interval?.partitionCount == nil)
    }

    @Test func testTableListingsReadPartitioningFromAllTablesWithoutJoiningAllPartTables() {
        let listings = [OracleSchemaQueries.tables(schema: "HR")] + OracleSchemaQueries.tables(inSchemas: ["HR", "SALES"])
        for sql in listings {
            #expect(!sql.contains("ALL_PART_TABLES"))
            #expect(sql.contains("CASE WHEN t.partitioned = 'YES' THEN 'Y' ELSE 'N' END AS is_partitioned"))
            #expect(sql.contains("NULL AS partition_count"))
        }
    }

    @Test func testPartitionCountsNameEveryOwnerAndOmitAnIntervalCount() throws {
        let statements = OracleSchemaQueries.partitionCounts(owners: ["HR", "O'BRIEN"])
        let sql = try #require(statements.first)
        #expect(statements.count == 1)
        #expect(sql.contains("FROM SYS.ALL_PART_TABLES"))
        #expect(sql.contains("WHERE owner IN ('HR', 'O''BRIEN')"))
        #expect(sql.contains("CASE WHEN interval IS NULL THEN partition_count END"))
        #expect(OracleSchemaQueries.partitionCounts(owners: []).isEmpty)
        #expect(OracleSchemaQueries.partitionCounts(owners: (0..<1_001).map { "U\($0)" }).count == 2)
    }

    @Test func testOnlyOwnersWithAPartitionedTableAreAskedForCounts() {
        let rows = [
            OracleTableRow(name: "ORDERS", isView: false, isPartitioned: true, schema: "SALES"),
            OracleTableRow(name: "EVENTS", isView: false, isPartitioned: true, schema: "SALES"),
            OracleTableRow(name: "EMPLOYEES", isView: false, schema: "HR"),
            OracleTableRow(name: "AUDIT", isView: false, isPartitioned: true)
        ]
        #expect(OracleSchemaQueries.ownersWithPartitionedTables(in: rows, defaultOwner: "APP") == ["APP", "SALES"])
        #expect(OracleSchemaQueries.ownersWithPartitionedTables(in: rows, defaultOwner: nil) == ["SALES"])
        #expect(OracleSchemaQueries.ownersWithPartitionedTables(in: [rows[2]], defaultOwner: "HR").isEmpty)
    }

    @Test func testPartitionCountsLandOnTheirOwnersTables() {
        let rows = [
            OracleTableRow(name: "ORDERS", isView: false, isPartitioned: true, schema: "SALES"),
            OracleTableRow(name: "ORDERS", isView: false, isPartitioned: true, schema: "ARCHIVE"),
            OracleTableRow(name: "EVENTS", isView: false, isPartitioned: true, schema: "SALES"),
            OracleTableRow(name: "EMPLOYEES", isView: false, schema: "SALES")
        ]
        let counts: [[OracleRawCell]] = [
            [.string("SALES"), .string("ORDERS"), .string("12")],
            [.string("ARCHIVE"), .string("ORDERS"), .string("4")],
            [.string("SALES"), .string("EVENTS"), .null],
            [.string("SALES"), .string("EMPLOYEES"), .string("3")]
        ]
        let merged = OracleSchemaQueries.applyingPartitionCounts(counts, to: rows, defaultOwner: nil)
        #expect(merged.map(\.partitionCount) == [12, 4, nil, nil])
        #expect(merged[2].isPartitioned)
    }

    @Test func testOneSchemaListingTakesItsCountsUnderTheDefaultOwner() {
        let rows = [OracleTableRow(name: "ORDERS", isView: false, isPartitioned: true)]
        let counts: [[OracleRawCell]] = [[.string("HR"), .string("ORDERS"), .string("8")]]
        let merged = OracleSchemaQueries.applyingPartitionCounts(counts, to: rows, defaultOwner: "HR")
        #expect(merged == [OracleTableRow(name: "ORDERS", isView: false, isPartitioned: true, partitionCount: 8)])
    }

    /// `HIGH_VALUE` is a LONG column OracleNIO cannot decode, so it must never be selected.
    @Test func testPartitionQueriesNeverReadHighValue() {
        let partitions = OracleSchemaQueries.partitions(schema: "HR", table: "ORDERS")
        let subpartitions = OracleSchemaQueries.subpartitions(schema: "HR", table: "ORDERS")
        #expect(!(partitions.lowercased().contains("high_value")))
        #expect(!(subpartitions.lowercased().contains("high_value")))
        #expect(partitions.contains("p.table_owner = 'HR'"))
        #expect(subpartitions.contains("s.table_name = 'ORDERS'"))
    }

    /// Every subpartition of the table in one statement, carrying its parent's name so the rows
    /// group in memory. Asking per partition was one round trip each, and one timeout among
    /// hundreds discarded the whole answer.
    @Test func testSubpartitionsAreFetchedForTheWholeTableAtOnce() {
        let sql = OracleSchemaQueries.subpartitions(schema: "HR", table: "ORDERS")
        #expect(sql.contains("s.partition_name"))
        #expect(!sql.contains("s.partition_name = '"))
        #expect(sql.contains("ORDER BY s.partition_name, s.subpartition_position"))
    }

    @Test func testParseSubpartitionRowCarriesItsParentName() {
        let parsed = OracleSchemaQueries.parseSubpartitionRow([
            .string("P1"), .string("P1_SP2"), .string("2"), .string("40")
        ])
        #expect(parsed?.parent == "P1")
        #expect(parsed?.row.name == "P1_SP2")
        #expect(parsed?.row.position == 2)
        #expect(parsed?.row.rowCount == 40)
        #expect(parsed?.row.isSubpartitioned == false)
    }

    @Test func testParseSubpartitionRowNeedsBothNames() {
        #expect(OracleSchemaQueries.parseSubpartitionRow([.string("P1")]) == nil)
        #expect(OracleSchemaQueries.parseSubpartitionRow([.null, .string("P1_SP1")]) == nil)
    }

    @Test func testParsePartitionRowReadsSubpartitionCount() {
        let composite = OracleSchemaQueries.parsePartitionRow([
            .string("P1"), .string("2"), .string("500"), .string("4")
        ])
        #expect(composite?.isSubpartitioned == true)
        #expect(composite?.position == 2)
        #expect(composite?.rowCount == 500)

        let leaf = OracleSchemaQueries.parsePartitionRow([
            .string("P2"), .string("3"), .null, .string("0")
        ])
        #expect(leaf?.isSubpartitioned == false)
        #expect(leaf?.rowCount == nil)
    }

    @Test func testParseTableRowReturnsNilWithoutAName() {
        #expect(OracleSchemaQueries.parseTableRow([.null, .string("VIEW")]) == nil)
        #expect(OracleSchemaQueries.parseTableRow([]) == nil)
    }

    @Test func testParseColumnRowReadsFlagsAndNullPrimaryKeyJoin() {
        let row: [OracleRawCell] = [
            .string("SALARY"), .string("NUMBER"), .string("22"), .string("10"), .string("2"),
            .string("N"), .string("N")
        ]
        let parsed = OracleSchemaQueries.parseColumnRow(row)
        #expect(parsed?.name == "SALARY")
        #expect(parsed?.dataType == "NUMBER")
        #expect(parsed?.isNullable == false)
        #expect(parsed?.isPrimaryKey == false)
        #expect(parsed?.displayType == "NUMBER(10,2)")
    }

    @Test func testParseColumnRowReadsTheDefault() {
        let row: [OracleRawCell] = [
            .string("CREATED"), .string("DATE"), .string("7"), .null, .null, .string("Y"), .string("N"),
            .string("sysdate\n  "), .string("NO"), .string("NO"), .string("NO"), .string("NO")
        ]
        #expect(OracleSchemaQueries.parseColumnRow(row)?.defaultValue == "sysdate")
    }

    @Test func testParseColumnRowWithoutADefaultReadsNil() {
        let row: [OracleRawCell] = [
            .string("NOTE"), .string("VARCHAR2"), .string("20"), .null, .null, .string("Y"), .string("N"),
            .null, .string("NO"), .string("NO"), .string("NO"), .string("NO")
        ]
        #expect(OracleSchemaQueries.parseColumnRow(row)?.defaultValue == nil)
    }

    /// Position 12 is `GENERATION_TYPE` from `ALL_TAB_IDENTITY_COLS`, which only an identity column has.
    @Test func testParseColumnRowReadsHowAnIdentityIsGeneratedAndWhetherAColumnIsVirtual() {
        let always: [OracleRawCell] = [
            .string("ID"), .string("NUMBER"), .string("22"), .null, .null, .string("N"), .string("Y"),
            .string("\"HR\".\"ISEQ$$_1\".nextval"), .string("NO"), .string("YES"), .string("NO"), .string("NO"),
            .string("ALWAYS")
        ]
        #expect(OracleSchemaQueries.parseColumnRow(always)?.identityGeneration == .always)
        #expect(OracleSchemaQueries.parseColumnRow(always)?.isVirtual == false)

        let byDefault: [OracleRawCell] = [
            .string("ID"), .string("NUMBER"), .string("22"), .null, .null, .string("N"), .string("Y"),
            .string("\"HR\".\"ISEQ$$_2\".nextval"), .string("NO"), .string("YES"), .string("NO"), .string("NO"),
            .string("BY DEFAULT")
        ]
        #expect(OracleSchemaQueries.parseColumnRow(byDefault)?.identityGeneration == .byDefault)

        let virtual: [OracleRawCell] = [
            .string("V"), .string("NUMBER"), .string("22"), .null, .null, .string("Y"), .string("N"),
            .string("LENGTH(\"NAME\")"), .string("YES"), .string("NO"), .string("NO"), .string("NO"), .null
        ]
        #expect(OracleSchemaQueries.parseColumnRow(virtual)?.identityGeneration == nil)
        #expect(OracleSchemaQueries.parseColumnRow(virtual)?.isVirtual == true)
    }

    @Test func testColumnsQueryReadsTheIdentityGenerationOnlyWhereTheReleaseHasIdentity() {
        let modern = OracleSchemaQueries.columns(schema: "HR", table: "T", release: OracleServerRelease(major: 23))
        #expect(modern.contains("i.GENERATION_TYPE FROM SYS.ALL_TAB_IDENTITY_COLS i"))
        let legacy = OracleSchemaQueries.columns(schema: "HR", table: "T", release: OracleServerRelease(major: 11))
        #expect(legacy.contains("NULL AS GENERATION_TYPE"))
        #expect(!legacy.contains("ALL_TAB_IDENTITY_COLS"))
    }

    /// Positions 8 and 9 are `VIRTUAL_COLUMN` and `IDENTITY_COLUMN`, in the order the projection writes them.
    @Test func testParseColumnRowDropsTheDefaultOfAnIdentityOrVirtualColumn() {
        let identity: [OracleRawCell] = [
            .string("ID"), .string("NUMBER"), .string("22"), .null, .null, .string("N"), .string("Y"),
            .string("\"HR\".\"ISEQ$$_73292\".nextval"), .string("NO"), .string("YES"), .string("NO"), .string("NO")
        ]
        #expect(OracleSchemaQueries.parseColumnRow(identity)?.defaultValue == nil)

        let virtual: [OracleRawCell] = [
            .string("TOTAL"), .string("NUMBER"), .string("22"), .null, .null, .string("Y"), .string("N"),
            .string("\"C_ZERO\"+1"), .string("YES"), .string("NO"), .string("NO"), .string("NO")
        ]
        #expect(OracleSchemaQueries.parseColumnRow(virtual)?.defaultValue == nil)
    }

    /// Positions 10 and 11 are `DEFAULT_ON_NULL` and `DEFAULT_ON_NULL_UPD`.
    @Test func testParseColumnRowReadsDefaultOnNull() {
        let onInsert: [OracleRawCell] = [
            .string("STATUS"), .string("VARCHAR2"), .string("10"), .null, .null, .string("N"), .string("N"),
            .string("'x'"), .string("NO"), .string("NO"), .string("YES"), .string("NO")
        ]
        #expect(OracleSchemaQueries.parseColumnRow(onInsert)?.defaultValue == "ON NULL 'x'")

        let onUpdate: [OracleRawCell] = [
            .string("STATUS"), .string("VARCHAR2"), .string("10"), .null, .null, .string("N"), .string("N"),
            .string("'u'"), .string("NO"), .string("NO"), .string("YES"), .string("YES")
        ]
        #expect(OracleSchemaQueries.parseColumnRow(onUpdate)?.defaultValue == "ON NULL FOR INSERT AND UPDATE 'u'")
    }

    @Test func testParseTableColumnRowReadsTheTableThenTheSameColumnShape() {
        let row: [OracleRawCell] = [
            .string("ORDERS"), .string("QTY"), .string("NUMBER"), .string("22"), .string("5"), .string("0"),
            .string("N"), .string("N"), .string("0"), .string("NO"), .string("NO"), .string("NO"), .string("NO")
        ]
        let parsed = OracleSchemaQueries.parseTableColumnRow(row)
        #expect(parsed?.table == "ORDERS")
        #expect(parsed?.column.name == "QTY")
        #expect(parsed?.column.displayType == "NUMBER(5)")
        #expect(parsed?.column.isNullable == false)
        #expect(parsed?.column.defaultValue == "0")
        #expect(OracleSchemaQueries.parseTableColumnRow([.null, .string("QTY")]) == nil)
    }

    /// 11g has no `IDENTITY_COLUMN`, `DEFAULT_ON_NULL` or `USER_GENERATED`, and naming any of them fails the statement
    /// with ORA-00904. Its `ALL_TAB_COLUMNS` is `ALL_TAB_COLS` without the hidden columns.
    @Test func testAnElevenGServerIsNeverAskedForAColumnItDoesNotHave() {
        let release = OracleServerRelease(major: 11)
        for sql in [
            OracleSchemaQueries.columns(schema: "HR", table: "T", release: release),
            OracleSchemaQueries.allColumns(schema: "HR", release: release)
        ] {
            #expect(!sql.contains("c.IDENTITY_COLUMN"), "\(sql)")
            #expect(!sql.contains("c.DEFAULT_ON_NULL"), "\(sql)")
            #expect(!sql.contains("USER_GENERATED"), "\(sql)")
            #expect(sql.contains("c.HIDDEN_COLUMN = 'NO'"), "\(sql)")
            #expect(sql.contains("'NO' AS IDENTITY_COLUMN"), "\(sql)")
            #expect(sql.contains("c.VIRTUAL_COLUMN"), "\(sql)")
            #expect(sql.contains("c.DATA_DEFAULT"), "\(sql)")
        }
    }

    /// From 12.1 `ALL_TAB_COLUMNS` is `ALL_TAB_COLS` where `USER_GENERATED = 'YES'`, which keeps invisible columns;
    /// filtering on `HIDDEN_COLUMN` there would drop them.
    @Test func testATwelveCServerReadsTheFlagsAndKeepsInvisibleColumns() {
        let release = OracleServerRelease(major: 19)
        for sql in [
            OracleSchemaQueries.columns(schema: "HR", table: "T", release: release),
            OracleSchemaQueries.allColumns(schema: "HR", release: release)
        ] {
            #expect(sql.contains("c.USER_GENERATED = 'YES'"), "\(sql)")
            #expect(!sql.contains("HIDDEN_COLUMN"), "\(sql)")
            #expect(sql.contains("c.IDENTITY_COLUMN AS IDENTITY_COLUMN"), "\(sql)")
            #expect(sql.contains("c.DEFAULT_ON_NULL AS DEFAULT_ON_NULL"), "\(sql)")
            #expect(sql.contains("'NO' AS DEFAULT_ON_NULL_UPD"), "\(sql)")
            #expect(!sql.contains("c.DEFAULT_ON_NULL_UPD"), "\(sql)")
        }
    }

    @Test func testA23aiServerReadsDefaultOnNullForUpdate() {
        for sql in [
            OracleSchemaQueries.columns(schema: "HR", table: "T", release: release23ai),
            OracleSchemaQueries.allColumns(schema: "HR", release: release23ai)
        ] {
            #expect(sql.contains("c.DEFAULT_ON_NULL_UPD AS DEFAULT_ON_NULL_UPD"), "\(sql)")
        }
    }

    /// The bulk read is parsed by dropping its first cell, so after `TABLE_NAME` its projection has to be the
    /// per-table one, column for column, and the parser reads by position, so every release projects the same count.
    @Test func testTheBulkReadProjectsTheTableNameThenThePerTableColumns() {
        for release in Self.releases {
            let single = projection(of: OracleSchemaQueries.columns(schema: "HR", table: "T", release: release))
            let bulk = projection(of: OracleSchemaQueries.allColumns(schema: "HR", release: release))
            #expect(bulk.first == "c.TABLE_NAME")
            #expect(Array(bulk.dropFirst()) == single, "release \(release)")
            #expect(single.count == 19, "release \(release)")
            #expect(single.last == "c.OWNER", "release \(release)")
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
    @Test func testNoReleaseIsAskedForATypeColumnItDoesNotHave() {
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
                    #expect(!names(sql, column), "release \(release) names \(column)")
                }
                for column in ["CHAR_LENGTH", "CHAR_USED", "DATA_TYPE_OWNER", "DATA_TYPE_MOD"] {
                    #expect(names(sql, column), "release \(release) does not name \(column)")
                }
            }
        }
    }

    @Test func testVectorInfoIsALiteralNullWhereTheReleaseLacksIt() {
        let legacy = OracleSchemaQueries.columns(schema: "HR", table: "T", release: OracleServerRelease(major: 23, update: 3))
        #expect(legacy.contains("NULL AS VECTOR_INFO"), "\(legacy)")
        let modern = OracleSchemaQueries.columns(schema: "HR", table: "T", release: release23ai)
        #expect(modern.contains("c.VECTOR_INFO AS VECTOR_INFO"), "\(modern)")
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
    @Test func testParseColumnRowReadsTheCharacterLengthAndSemantics() {
        let national = OracleSchemaQueries.parseColumnRow(
            columnRow("NOTE", type: "NVARCHAR2", length: "200", charLength: "100", charUsed: "C")
        )
        #expect(national?.displayType == "NVARCHAR2(100)")
        #expect(national?.charLength == 100)
        #expect(national?.classificationTypeName == nil)

        let characters = OracleSchemaQueries.parseColumnRow(
            columnRow("NAME", type: "VARCHAR2", length: "200", charLength: "50", charUsed: "C")
        )
        #expect(characters?.displayType == "VARCHAR2(50 CHAR)")
        #expect(characters?.dataLength == "200")
    }

    @Test func testParseColumnRowQualifiesATypeFromAnotherSchema() {
        let geometry = OracleSchemaQueries.parseColumnRow(
            columnRow("SHAPE", type: "SDO_GEOMETRY", length: "1", typeOwner: "MDSYS")
        )
        #expect(geometry?.displayType == "\"MDSYS\".\"SDO_GEOMETRY\"")
        #expect(geometry?.classificationTypeName == "SDO_GEOMETRY")

        let reference = OracleSchemaQueries.parseColumnRow(
            columnRow("ADDR", type: "ADDRESS_T", length: "50", typeOwner: "HR", typeModifier: "REF")
        )
        #expect(reference?.displayType == "REF ADDRESS_T")
        #expect(reference?.classificationTypeName == "ADDRESS_T")
    }

    @Test func testParseColumnRowKeepsTheCaseOfAQuotedTypeName() {
        let mixed = OracleSchemaQueries.parseColumnRow(
            columnRow("M", type: "Mixed_T", length: "1", typeOwner: "HR")
        )
        #expect(mixed?.dataType == "Mixed_T")
        #expect(mixed?.displayType == "\"Mixed_T\"")
    }

    @Test func testParseColumnRowReadsVectorInfo() {
        let vector = OracleSchemaQueries.parseColumnRow(
            columnRow("EMBEDDING", type: "VECTOR", length: "8200", charLength: "3", vectorInfo: "VECTOR(3,FLOAT32,DENSE)")
        )
        #expect(vector?.displayType == "VECTOR(3, FLOAT32)")
        #expect(vector?.charLength == nil)
    }

    /// Oracle stores a virtual column's expression rewritten, `"A"+1` for `a + 1`, in `DATA_DEFAULT` (measured).
    @Test func testParseColumnRowReadsTheExpressionOfAVirtualColumn() {
        let virtual = OracleSchemaQueries.parseColumnRow(
            columnRow("V", type: "NUMBER", length: "22", storedDefault: "\"A\"+1\n  ", isVirtual: true)
        )
        #expect(virtual?.generationExpression == "\"A\"+1")
        #expect(virtual?.defaultValue == nil)

        let plain = OracleSchemaQueries.parseColumnRow(
            columnRow("D", type: "NUMBER", length: "22", storedDefault: "5 /* five */")
        )
        #expect(plain?.generationExpression == nil)
        #expect(plain?.defaultValue == "5")
    }

    @Test func testParseColumnRowClassifiesADateAsATimestamp() {
        let date = OracleSchemaQueries.parseColumnRow(columnRow("CREATED", type: "DATE", length: "7"))
        #expect(date?.displayType == "DATE")
        #expect(date?.classificationTypeName == "TIMESTAMP(0)")
    }

    @Test func testTheBulkRowReadsTheSameTypeColumns() {
        let row = [OracleRawCell.string("NOTES")]
            + columnRow("NOTE", type: "NVARCHAR2", length: "200", charLength: "100", charUsed: "C")
        #expect(OracleSchemaQueries.parseTableColumnRow(row)?.column.displayType == "NVARCHAR2(100)")
    }

    @Test func testParseColumnRowTreatsMissingTypeAsVarchar2() {
        let parsed = OracleSchemaQueries.parseColumnRow([.string("C"), .null, .null, .null, .null, .string("Y"), .string("Y")])
        #expect(parsed?.dataType == "VARCHAR2")
        #expect(parsed?.isNullable == true)
        #expect(parsed?.isPrimaryKey == true)
    }

    @Test func testParseIndexRowReadsUniquenessAndPrimaryFlag() {
        let row: [OracleRawCell] = [.string("PK_EMP"), .string("UNIQUE"), .string("EMP_ID"), .string("Y")]
        #expect(OracleSchemaQueries.parseIndexRow(row) == OracleIndexRow(name: "PK_EMP", isUnique: true, columnName: "EMP_ID", isPrimary: true))

        let nonUnique: [OracleRawCell] = [.string("IX_DEPT"), .string("NONUNIQUE"), .string("DEPT_ID"), .string("N")]
        #expect(OracleSchemaQueries.parseIndexRow(nonUnique) == OracleIndexRow(name: "IX_DEPT", isUnique: false, columnName: "DEPT_ID", isPrimary: false))
    }

    @Test func testParseIndexRowReturnsNilWithoutAColumn() {
        #expect(OracleSchemaQueries.parseIndexRow([.string("IX"), .string("UNIQUE"), .null, .string("N")]) == nil)
    }

    @Test func testParseForeignKeyRowReadsReferenceAndDeleteRule() {
        let row: [OracleRawCell] = [
            .string("FK_EMP_DEPT"), .string("DEPT_ID"), .string("DEPARTMENTS"), .string("ID"),
            .string("CASCADE"), .string("HR")
        ]
        #expect(OracleSchemaQueries.parseForeignKeyRow(row) == OracleForeignKeyRow(
                constraintName: "FK_EMP_DEPT",
                columnName: "DEPT_ID",
                referencedTable: "DEPARTMENTS",
                referencedColumn: "ID",
                referencedSchema: "HR",
                deleteRule: "CASCADE"
            ))
    }

    @Test func testParseForeignKeyRowDefaultsDeleteRule() {
        let row: [OracleRawCell] = [
            .string("FK"), .string("C"), .string("T"), .string("ID"), .null, .null
        ]
        #expect(OracleSchemaQueries.parseForeignKeyRow(row)?.deleteRule == "NO ACTION")
        #expect(OracleSchemaQueries.parseForeignKeyRow(row)?.referencedSchema == nil)
    }
}
