import Foundation
import TableProMSSQLCore
import Testing

struct MSSQLNativeCellTextTests {
    private func text<T>(_ value: T, as type: MSSQLColumnType) -> String? {
        withUnsafeBytes(of: value) { MSSQLNativeCellText.text($0, type: type) }
    }

    @Test("Integers read as their decimal digits across each type's whole range")
    func integers() {
        #expect(text(UInt8(0), as: .tinyInt) == "0")
        #expect(text(UInt8(255), as: .tinyInt) == "255")
        #expect(text(Int16.min, as: .smallInt) == "-32768")
        #expect(text(Int16.max, as: .smallInt) == "32767")
        #expect(text(Int32.min, as: .int) == "-2147483648")
        #expect(text(Int32(42), as: .int) == "42")
        #expect(text(Int64.min, as: .bigInt) == "-9223372036854775808")
        #expect(text(Int64.max, as: .bigInt) == "9223372036854775807")
    }

    @Test("A bit reads as 1 or 0, as dbconvert writes it")
    func bit() {
        #expect(text(UInt8(0), as: .bit) == "0")
        #expect(text(UInt8(1), as: .bit) == "1")
    }

    @Test("Bytes at an odd address still read whole")
    func unalignedRead() {
        let bytes: [UInt8] = [0xFF, 0x78, 0x56, 0x34, 0x12]
        let read = bytes.withUnsafeBytes { raw in
            MSSQLNativeCellText.text(UnsafeRawBufferPointer(rebasing: raw[1...]), type: .int)
        }
        #expect(read == "305419896")
    }

    @Test("A length that is not the type's, and any other type, go to dbconvert")
    func othersAnswerNil() {
        #expect(text(Int32(1), as: .bigInt) == nil)
        #expect(text(Int64(1), as: .int) == nil)
        #expect(text(Double(1.5), as: .float) == nil)
        #expect(text(Int64(1), as: .money) == nil)
        #expect(text(Int32(1), as: .dateTime) == nil)
        #expect(MSSQLNativeCellText.text(UnsafeRawBufferPointer(start: nil, count: 0), type: .int) == nil)
    }
}
