@testable import TableProOracleCore
import XCTest

/// Each dictionary row here is what `USER_TAB_COLS` reported on Oracle 23ai (AL32UTF8, AL16UTF16) for the column
/// declared beside it, and each expected spelling recreated that same row through `CREATE TABLE` (measured).
final class OracleColumnTypeSpellingTests: XCTestCase {
    private struct Shape {
        let declared: String
        let row: OracleColumnTypeSpelling
        let spelling: String
    }

    private func row(
        _ dataType: String,
        length: Int? = nil,
        precision: Int? = nil,
        scale: Int? = nil,
        charLength: Int? = nil,
        charUsed: String? = nil,
        owner: String? = nil,
        modifier: String? = nil,
        vectorInfo: String? = nil
    ) -> OracleColumnTypeSpelling {
        OracleColumnTypeSpelling(
            dataType: dataType,
            dataLength: length,
            precision: precision,
            scale: scale,
            charLength: charLength,
            charUsed: charUsed,
            typeOwner: owner,
            typeModifier: modifier,
            vectorInfo: vectorInfo,
            tableOwner: "PROBE"
        )
    }

    private func assertShapes(_ shapes: [Shape], file: StaticString = #filePath, line: UInt = #line) {
        for shape in shapes {
            XCTAssertEqual(shape.row.declaration, shape.spelling, "declared \(shape.declared)", file: file, line: line)
        }
    }

    func testCharacterTypesSpellTheirDeclaredLength() {
        assertShapes([
            Shape(declared: "NVARCHAR2(100)", row: row("NVARCHAR2", length: 200, charLength: 100, charUsed: "C"), spelling: "NVARCHAR2(100)"),
            Shape(declared: "NCHAR(10)", row: row("NCHAR", length: 20, charLength: 10, charUsed: "C"), spelling: "NCHAR(10)"),
            Shape(declared: "NCHAR", row: row("NCHAR", length: 2, charLength: 1, charUsed: "C"), spelling: "NCHAR(1)"),
            Shape(declared: "VARCHAR2(50 CHAR)", row: row("VARCHAR2", length: 200, charLength: 50, charUsed: "C"), spelling: "VARCHAR2(50 CHAR)"),
            Shape(declared: "VARCHAR2(50 BYTE)", row: row("VARCHAR2", length: 50, charLength: 50, charUsed: "B"), spelling: "VARCHAR2(50 BYTE)"),
            Shape(declared: "VARCHAR2(50)", row: row("VARCHAR2", length: 50, charLength: 50, charUsed: "B"), spelling: "VARCHAR2(50 BYTE)"),
            Shape(declared: "CHAR(10 CHAR)", row: row("CHAR", length: 40, charLength: 10, charUsed: "C"), spelling: "CHAR(10 CHAR)"),
            Shape(declared: "CHAR", row: row("CHAR", length: 1, charLength: 1, charUsed: "B"), spelling: "CHAR(1 BYTE)"),
            Shape(declared: "NATIONAL CHARACTER VARYING(7)", row: row("NVARCHAR2", length: 14, charLength: 7, charUsed: "C"), spelling: "NVARCHAR2(7)"),
            Shape(declared: "VARCHAR2(100) DOMAIN d", row: row("VARCHAR2", length: 100, charLength: 100, charUsed: "B"), spelling: "VARCHAR2(100 BYTE)")
        ])
    }

    /// `NUMBER(*,s)` and `INTEGER` report no precision and keep their scale; a negative scale is kept.
    func testNumericTypesKeepStarPrecisionAndNegativeScale() {
        assertShapes([
            Shape(declared: "NUMBER", row: row("NUMBER", length: 22, charLength: 0), spelling: "NUMBER"),
            Shape(declared: "NUMBER(*)", row: row("NUMBER", length: 22, charLength: 0), spelling: "NUMBER"),
            Shape(declared: "NUMBER(10)", row: row("NUMBER", length: 22, precision: 10, scale: 0), spelling: "NUMBER(10)"),
            Shape(declared: "NUMBER(10,2)", row: row("NUMBER", length: 22, precision: 10, scale: 2), spelling: "NUMBER(10,2)"),
            Shape(declared: "NUMBER(*,2)", row: row("NUMBER", length: 22, scale: 2), spelling: "NUMBER(*,2)"),
            Shape(declared: "NUMBER(5,-2)", row: row("NUMBER", length: 22, precision: 5, scale: -2), spelling: "NUMBER(5,-2)"),
            Shape(declared: "INTEGER", row: row("NUMBER", length: 22, scale: 0), spelling: "NUMBER(*,0)"),
            Shape(declared: "NUMBER(38)", row: row("NUMBER", length: 22, precision: 38, scale: 0), spelling: "NUMBER(38)"),
            Shape(declared: "FLOAT", row: row("FLOAT", length: 22, precision: 126), spelling: "FLOAT(126)"),
            Shape(declared: "FLOAT(10)", row: row("FLOAT", length: 22, precision: 10), spelling: "FLOAT(10)"),
            Shape(declared: "DOUBLE PRECISION", row: row("FLOAT", length: 22, precision: 126), spelling: "FLOAT(126)"),
            Shape(declared: "REAL", row: row("FLOAT", length: 22, precision: 63), spelling: "FLOAT(63)"),
            Shape(declared: "BINARY_FLOAT", row: row("BINARY_FLOAT", length: 4), spelling: "BINARY_FLOAT"),
            Shape(declared: "BINARY_DOUBLE", row: row("BINARY_DOUBLE", length: 8), spelling: "BINARY_DOUBLE")
        ])
    }

    /// `DATA_TYPE` already carries the fractional and leading precisions, with the defaults filled in.
    func testDatetimeAndIntervalTypesAreTheirDataTypeVerbatim() {
        assertShapes([
            Shape(declared: "DATE", row: row("DATE", length: 7), spelling: "DATE"),
            Shape(declared: "TIMESTAMP", row: row("TIMESTAMP(6)", length: 11, scale: 6), spelling: "TIMESTAMP(6)"),
            Shape(declared: "TIMESTAMP(0)", row: row("TIMESTAMP(0)", length: 7, scale: 0), spelling: "TIMESTAMP(0)"),
            Shape(
                declared: "TIMESTAMP(9) WITH TIME ZONE",
                row: row("TIMESTAMP(9) WITH TIME ZONE", length: 13, scale: 9),
                spelling: "TIMESTAMP(9) WITH TIME ZONE"
            ),
            Shape(
                declared: "TIMESTAMP WITH LOCAL TIME ZONE",
                row: row("TIMESTAMP(6) WITH LOCAL TIME ZONE", length: 11, scale: 6),
                spelling: "TIMESTAMP(6) WITH LOCAL TIME ZONE"
            ),
            Shape(
                declared: "INTERVAL YEAR TO MONTH",
                row: row("INTERVAL YEAR(2) TO MONTH", length: 5, precision: 2, scale: 0),
                spelling: "INTERVAL YEAR(2) TO MONTH"
            ),
            Shape(
                declared: "INTERVAL DAY(3) TO SECOND(0)",
                row: row("INTERVAL DAY(3) TO SECOND(0)", length: 11, precision: 3, scale: 0),
                spelling: "INTERVAL DAY(3) TO SECOND(0)"
            )
        ])
    }

    func testBinaryRowidAndLargeObjectTypes() {
        assertShapes([
            Shape(declared: "RAW(16)", row: row("RAW", length: 16), spelling: "RAW(16)"),
            Shape(declared: "UROWID", row: row("UROWID", length: 4_000), spelling: "UROWID"),
            Shape(declared: "UROWID(4000)", row: row("UROWID", length: 4_000), spelling: "UROWID"),
            Shape(declared: "UROWID(100)", row: row("UROWID", length: 100), spelling: "UROWID(100)"),
            Shape(declared: "ROWID", row: row("ROWID", length: 10), spelling: "ROWID"),
            Shape(declared: "BLOB", row: row("BLOB", length: 4_000), spelling: "BLOB"),
            Shape(declared: "CLOB", row: row("CLOB", length: 4_000), spelling: "CLOB"),
            Shape(declared: "NCLOB", row: row("NCLOB", length: 4_000), spelling: "NCLOB"),
            Shape(declared: "BFILE", row: row("BFILE", length: 530), spelling: "BFILE"),
            Shape(declared: "LONG", row: row("LONG", length: 0), spelling: "LONG"),
            Shape(declared: "LONG RAW", row: row("LONG RAW", length: 0), spelling: "LONG RAW"),
            Shape(declared: "JSON", row: row("JSON", length: 8_200), spelling: "JSON"),
            Shape(declared: "BOOLEAN", row: row("BOOLEAN", length: 1), spelling: "BOOLEAN")
        ])
    }

    /// `VECTOR_INFO` spells every part; `DENSE` and trailing `*` are the defaults a declaration leaves out.
    func testVectorSpellsItsVectorInfo() {
        let vector = { (info: String, dimensions: Int) in self.row("VECTOR", length: 8_200, charLength: dimensions, vectorInfo: info) }
        assertShapes([
            Shape(declared: "VECTOR", row: vector("VECTOR(*,*,DENSE)", 0), spelling: "VECTOR"),
            Shape(declared: "VECTOR(*, *)", row: vector("VECTOR(*,*,DENSE)", 0), spelling: "VECTOR"),
            Shape(declared: "VECTOR(3)", row: vector("VECTOR(3,*,DENSE)", 3), spelling: "VECTOR(3)"),
            Shape(declared: "VECTOR(3, FLOAT32)", row: vector("VECTOR(3,FLOAT32,DENSE)", 3), spelling: "VECTOR(3, FLOAT32)"),
            Shape(declared: "VECTOR(*, INT8)", row: vector("VECTOR(*,INT8,DENSE)", 0), spelling: "VECTOR(*, INT8)"),
            Shape(declared: "VECTOR(1024, BINARY)", row: vector("VECTOR(1024,BINARY,DENSE)", 1_024), spelling: "VECTOR(1024, BINARY)"),
            Shape(declared: "VECTOR(*, *, SPARSE)", row: vector("VECTOR(*,*,SPARSE)", 0), spelling: "VECTOR(*, *, SPARSE)"),
            Shape(declared: "VECTOR(3, *, SPARSE)", row: vector("VECTOR(3,*,SPARSE)", 3), spelling: "VECTOR(3, *, SPARSE)"),
            Shape(
                declared: "VECTOR(100, FLOAT64, SPARSE)",
                row: vector("VECTOR(100,FLOAT64,SPARSE)", 100),
                spelling: "VECTOR(100, FLOAT64, SPARSE)"
            )
        ])
    }

    /// Before 23.4 the query projects `NULL` for `VECTOR_INFO`, and `CHAR_LENGTH` still carries the dimension count.
    func testVectorWithoutVectorInfoKeepsTheDimensionCount() {
        XCTAssertEqual(row("VECTOR", length: 8_200, charLength: 3).declaration, "VECTOR(3, *)")
        XCTAssertEqual(row("VECTOR", length: 8_200, charLength: 0).declaration, "VECTOR")
        XCTAssertEqual(row("VECTOR", length: 8_200).declaration, "VECTOR")
    }

    func testAnUnreadableVectorInfoFallsBackToTheDimensionCount() {
        XCTAssertEqual(row("VECTOR", charLength: 3, vectorInfo: "VECTOR").declaration, "VECTOR(3, *)")
        XCTAssertEqual(row("VECTOR", charLength: 3, vectorInfo: "VECTOR(3,,DENSE)").declaration, "VECTOR(3, *)")
    }

    /// `PUBLIC` owns `XMLTYPE` declared plainly; `SYS.XMLTYPE` and `SYS.ANYDATA` report `SYS`.
    func testATypeOfAnotherSchemaIsQualifiedWithItsOwner() {
        assertShapes([
            Shape(declared: "XMLTYPE", row: row("XMLTYPE", length: 2_000, owner: "PUBLIC"), spelling: "XMLTYPE"),
            Shape(declared: "SYS.XMLTYPE", row: row("XMLTYPE", length: 2_000, owner: "SYS"), spelling: "\"SYS\".\"XMLTYPE\""),
            Shape(declared: "SYS.ANYDATA", row: row("ANYDATA", length: 3_752, owner: "SYS"), spelling: "\"SYS\".\"ANYDATA\""),
            Shape(declared: "MDSYS.SDO_GEOMETRY", row: row("SDO_GEOMETRY", length: 1, owner: "MDSYS"), spelling: "\"MDSYS\".\"SDO_GEOMETRY\""),
            Shape(declared: "S_OBJ", row: row("S_OBJ", length: 1, owner: "PROBE"), spelling: "S_OBJ"),
            Shape(declared: "S_VARR", row: row("S_VARR", length: 132, owner: "PROBE"), spelling: "S_VARR")
        ])
    }

    func testAnOwnerOrTypeNameWithAQuoteIsEscaped() {
        XCTAssertEqual(row("T\"X", length: 1, owner: "O\"WN").declaration, "\"O\"\"WN\".\"T\"\"X\"")
    }

    func testARefNamesTheTypeItPointsTo() {
        assertShapes([
            Shape(declared: "REF S_OBJ", row: row("S_OBJ", length: 50, owner: "PROBE", modifier: "REF"), spelling: "REF S_OBJ"),
            Shape(declared: "REF HR.ADDRESS_T", row: row("ADDRESS_T", length: 50, owner: "HR", modifier: "REF"), spelling: "REF \"HR\".\"ADDRESS_T\""),
            Shape(declared: "REF \"S_Mixed\"", row: row("S_Mixed", length: 50, owner: "PROBE", modifier: "REF"), spelling: "REF \"S_Mixed\"")
        ])
    }

    /// A type created under a quoted mixed-case name only resolves under that exact name, so it is never case-folded
    /// and is quoted when an unquoted name would read as another.
    func testATypeNameIsNeverCaseFolded() {
        XCTAssertEqual(row("S_Mixed", length: 1, owner: "PROBE").declaration, "\"S_Mixed\"")
        XCTAssertEqual(row("S_Mixed", length: 1, owner: "PROBE").dataType, "S_Mixed")
        XCTAssertEqual(row("TYPE WITH SPACE", length: 1, owner: "PROBE").declaration, "\"TYPE WITH SPACE\"")
    }

    /// A built-in name is a keyword, so a lowercase one is still recognised, and the case it came in is kept.
    func testABuiltInNameIsRecognisedInAnyCase() {
        XCTAssertEqual(row("number", precision: 10, scale: 2).declaration, "number(10,2)")
        XCTAssertEqual(row("nvarchar2", length: 20, charLength: 10, charUsed: "C").declaration, "nvarchar2(10)")
    }

    func testMissingLengthsLeaveTheBareTypeName() {
        XCTAssertEqual(row("VARCHAR2").declaration, "VARCHAR2")
        XCTAssertEqual(row("NVARCHAR2").declaration, "NVARCHAR2")
        XCTAssertEqual(row("RAW").declaration, "RAW")
        XCTAssertEqual(row("FLOAT").declaration, "FLOAT")
        XCTAssertEqual(row("UROWID").declaration, "UROWID")
    }

    /// `DATA_LENGTH` is the byte count, so it stands in for a missing `CHAR_LENGTH` only under byte semantics.
    func testDataLengthStandsInForCharLengthOnlyUnderByteSemantics() {
        XCTAssertEqual(row("VARCHAR2", length: 50, charUsed: "B").declaration, "VARCHAR2(50 BYTE)")
        XCTAssertEqual(row("VARCHAR2", length: 200, charUsed: "C").declaration, "VARCHAR2")
    }

    func testClassificationTypeName() {
        XCTAssertEqual(row("DATE", length: 7).classificationTypeName, "TIMESTAMP(0)")
        XCTAssertEqual(row("XMLTYPE", owner: "SYS").classificationTypeName, "XMLTYPE")
        XCTAssertEqual(row("SDO_GEOMETRY", owner: "MDSYS").classificationTypeName, "SDO_GEOMETRY")
        XCTAssertEqual(row("S_OBJ", owner: "PROBE", modifier: "REF").classificationTypeName, "S_OBJ")
        XCTAssertEqual(row("S_Mixed", owner: "PROBE").classificationTypeName, "S_Mixed")
        XCTAssertNil(row("XMLTYPE", owner: "PUBLIC").classificationTypeName)
        XCTAssertNil(row("S_OBJ", owner: "PROBE").classificationTypeName)
        XCTAssertNil(row("TIMESTAMP(0)", scale: 0).classificationTypeName)
        XCTAssertNil(row("NUMBER", precision: 10, scale: 0).classificationTypeName)
        XCTAssertNil(row("NVARCHAR2", length: 200, charLength: 100, charUsed: "C").classificationTypeName)
    }

    /// `CHAR_LENGTH` is also a `VECTOR`'s dimension count and 0 for a `NUMBER`, neither of which is a length.
    func testCharacterLengthIsOnlyForTheFourCharacterTypes() {
        XCTAssertEqual(row("VARCHAR2", length: 50, charLength: 50, charUsed: "B").characterLength, 50)
        XCTAssertEqual(row("VARCHAR2", length: 200, charLength: 50, charUsed: "C").characterLength, 50)
        XCTAssertEqual(row("CHAR", length: 40, charLength: 10, charUsed: "C").characterLength, 10)
        XCTAssertEqual(row("NVARCHAR2", length: 200, charLength: 100, charUsed: "C").characterLength, 100)
        XCTAssertEqual(row("NCHAR", length: 2, charLength: 1, charUsed: "C").characterLength, 1)
        XCTAssertNil(row("VECTOR", length: 8_200, charLength: 3, vectorInfo: "VECTOR(3,FLOAT32,DENSE)").characterLength)
        XCTAssertNil(row("NUMBER", length: 22, charLength: 0).characterLength)
        XCTAssertNil(row("RAW", length: 16).characterLength)
        XCTAssertNil(row("CLOB", length: 4_000).characterLength)
    }
}
