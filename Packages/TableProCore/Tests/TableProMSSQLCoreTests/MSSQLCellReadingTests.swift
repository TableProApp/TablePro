import Foundation
import Testing

@testable import TableProMSSQLCore

@Suite("MSSQL cell reading")
struct MSSQLCellReadingTests {
    @Test("An empty string is a value, not NULL", arguments: [MSSQLColumnType.char, .varchar, .text, .nvarchar, .ntext])
    func emptyStringIsText(type: MSSQLColumnType) {
        #expect(MSSQLCellReading(type: type, hasData: true, length: 0) == .emptyText)
    }

    @Test("An empty binary value is bytes, not NULL", arguments: [MSSQLColumnType.binary, .varbinary, .image])
    func emptyBinaryIsBytes(type: MSSQLColumnType) {
        #expect(MSSQLCellReading(type: type, hasData: true, length: 0) == .bytes)
    }

    @Test("Only a missing pointer is NULL", arguments: [MSSQLColumnType.varchar, .varbinary, .bit, .int, .sqlVariant])
    func missingPointerIsNull(type: MSSQLColumnType) {
        #expect(MSSQLCellReading(type: type, hasData: false, length: 0) == .null)
    }

    @Test("A value with content is read as text")
    func valueIsText() {
        #expect(MSSQLCellReading(type: .varchar, hasData: true, length: 3) == .text)
        #expect(MSSQLCellReading(type: .bit, hasData: true, length: 1) == .text)
        #expect(MSSQLCellReading(type: .dateTimeOffset, hasData: true, length: 16) == .text)
    }

    @Test("A sql_variant never reaches a conversion")
    func variantIsUnreadable() {
        #expect(MSSQLCellReading(type: .sqlVariant, hasData: true, length: 24) == .unreadable)
        #expect(MSSQLCellReading(type: .sqlVariant, hasData: true, length: 0) == .unreadable)
    }
}
