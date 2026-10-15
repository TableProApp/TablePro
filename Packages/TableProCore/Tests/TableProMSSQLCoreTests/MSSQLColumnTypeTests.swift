import Foundation
@testable import TableProMSSQLCore
import Testing

struct MSSQLColumnTypeTests {
    @Test func testIsBinaryCoversBinaryFamily() {
        #expect(MSSQLColumnType.binary.isBinary)
        #expect(MSSQLColumnType.varbinary.isBinary)
        #expect(MSSQLColumnType.image.isBinary)
        #expect(!MSSQLColumnType.varchar.isBinary)
        #expect(!MSSQLColumnType.int.isBinary)
    }

    @Test func testIsDateOrTimeCoversAllDateTimeVariants() {
        let dateTypes: [MSSQLColumnType] = [
            .dateTime, .smallDateTime, .dateTimeN,
            .date, .time, .dateTime2, .dateTimeOffset
        ]
        for type in dateTypes {
            #expect(type.isDateOrTime, "\(type.canonicalName) should be date/time")
        }
        #expect(!MSSQLColumnType.int.isDateOrTime)
        #expect(!MSSQLColumnType.varchar.isDateOrTime)
    }

    @Test func testIsUnicodeStringOnlyForNTypes() {
        #expect(MSSQLColumnType.nchar.isUnicodeString)
        #expect(MSSQLColumnType.nvarchar.isUnicodeString)
        #expect(MSSQLColumnType.ntext.isUnicodeString)
        #expect(!MSSQLColumnType.char.isUnicodeString)
        #expect(!MSSQLColumnType.varchar.isUnicodeString)
    }

    @Test func testIsNarrowStringOnlyForNonUnicodeStrings() {
        #expect(MSSQLColumnType.char.isNarrowString)
        #expect(MSSQLColumnType.varchar.isNarrowString)
        #expect(MSSQLColumnType.text.isNarrowString)
        #expect(!MSSQLColumnType.nvarchar.isNarrowString)
        #expect(!MSSQLColumnType.int.isNarrowString)
    }

    @Test func testCanonicalNameForDateTimeFamily() {
        #expect(MSSQLColumnType.dateTime.canonicalName == "datetime")
        #expect(MSSQLColumnType.dateTimeN.canonicalName == "datetime")
        #expect(MSSQLColumnType.smallDateTime.canonicalName == "smalldatetime")
        #expect(MSSQLColumnType.dateTime2.canonicalName == "datetime2")
        #expect(MSSQLColumnType.dateTimeOffset.canonicalName == "datetimeoffset")
    }

    @Test func testUnknownTypePreservesToken() {
        let unknown = MSSQLColumnType.unknown(99)
        #expect(unknown.canonicalName == "unknown")
        if case .unknown(let token) = unknown {
            #expect(token == 99)
        } else {
            Issue.record("expected .unknown case")
        }
    }
}
