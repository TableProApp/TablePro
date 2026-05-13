import XCTest
@testable import TableProMSSQLCore

final class MSSQLColumnTypeTests: XCTestCase {
    func testIsBinaryCoversBinaryFamily() {
        XCTAssertTrue(MSSQLColumnType.binary.isBinary)
        XCTAssertTrue(MSSQLColumnType.varbinary.isBinary)
        XCTAssertTrue(MSSQLColumnType.image.isBinary)
        XCTAssertFalse(MSSQLColumnType.varchar.isBinary)
        XCTAssertFalse(MSSQLColumnType.int.isBinary)
    }

    func testIsDateOrTimeCoversAllDateTimeVariants() {
        let dateTypes: [MSSQLColumnType] = [
            .dateTime, .smallDateTime, .dateTimeN,
            .date, .time, .dateTime2, .dateTimeOffset
        ]
        for type in dateTypes {
            XCTAssertTrue(type.isDateOrTime, "\(type.canonicalName) should be date/time")
        }
        XCTAssertFalse(MSSQLColumnType.int.isDateOrTime)
        XCTAssertFalse(MSSQLColumnType.varchar.isDateOrTime)
    }

    func testIsUnicodeStringOnlyForNTypes() {
        XCTAssertTrue(MSSQLColumnType.nchar.isUnicodeString)
        XCTAssertTrue(MSSQLColumnType.nvarchar.isUnicodeString)
        XCTAssertTrue(MSSQLColumnType.ntext.isUnicodeString)
        XCTAssertFalse(MSSQLColumnType.char.isUnicodeString)
        XCTAssertFalse(MSSQLColumnType.varchar.isUnicodeString)
    }

    func testIsNarrowStringOnlyForNonUnicodeStrings() {
        XCTAssertTrue(MSSQLColumnType.char.isNarrowString)
        XCTAssertTrue(MSSQLColumnType.varchar.isNarrowString)
        XCTAssertTrue(MSSQLColumnType.text.isNarrowString)
        XCTAssertFalse(MSSQLColumnType.nvarchar.isNarrowString)
        XCTAssertFalse(MSSQLColumnType.int.isNarrowString)
    }

    func testCanonicalNameForDateTimeFamily() {
        XCTAssertEqual(MSSQLColumnType.dateTime.canonicalName, "datetime")
        XCTAssertEqual(MSSQLColumnType.dateTimeN.canonicalName, "datetime")
        XCTAssertEqual(MSSQLColumnType.smallDateTime.canonicalName, "smalldatetime")
        XCTAssertEqual(MSSQLColumnType.dateTime2.canonicalName, "datetime2")
        XCTAssertEqual(MSSQLColumnType.dateTimeOffset.canonicalName, "datetimeoffset")
    }

    func testUnknownTypePreservesToken() {
        let unknown = MSSQLColumnType.unknown(99)
        XCTAssertEqual(unknown.canonicalName, "unknown")
        if case .unknown(let token) = unknown {
            XCTAssertEqual(token, 99)
        } else {
            XCTFail("expected .unknown case")
        }
    }
}
