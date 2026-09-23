//
//  ByteOrderMarkTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Byte order mark")
struct ByteOrderMarkTests {
    @Test("Each mark is recognised at the start of its text")
    func recognisesEachMark() {
        let marks: [(bytes: [UInt8], mark: ByteOrderMark)] = [
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian)
        ]

        for (bytes, mark) in marks {
            #expect(ByteOrderMark.leading(Data(bytes) + Data("x".utf8)) == mark, "\(bytes)")
            #expect(mark.length == bytes.count, "\(bytes)")
            #expect(mark.length <= ByteOrderMark.longestLength, "\(bytes)")
        }
    }

    @Test("A UTF-32 little-endian mark is not read as a UTF-16 mark followed by a null")
    func prefersTheLongerMark() throws {
        let text = try #require("a".data(using: .utf32LittleEndian))

        let mark = ByteOrderMark.leading(Data([0xFF, 0xFE, 0x00, 0x00]) + text)

        #expect(mark == .utf32LittleEndian)
        #expect(mark?.encoding == .utf32)
        #expect(mark?.byteOrderedEncoding == .utf32LittleEndian)
        #expect(mark?.codeUnitLength == 4)
    }

    @Test("A declared encoding only takes the marks it can carry")
    func honoursTheDeclaredEncoding() {
        let utf32LittleEndianStart = Data([0xFF, 0xFE, 0x00, 0x00, 0x61, 0x00])

        #expect(ByteOrderMark.leading(utf32LittleEndianStart, allowedBy: .utf16) == .utf16LittleEndian)
        #expect(ByteOrderMark.leading(utf32LittleEndianStart, allowedBy: .utf16LittleEndian) == .utf16LittleEndian)
        #expect(ByteOrderMark.leading(utf32LittleEndianStart, allowedBy: .utf32) == .utf32LittleEndian)
        #expect(ByteOrderMark.leading(utf32LittleEndianStart, allowedBy: .utf16BigEndian) == nil)
        #expect(ByteOrderMark.leading(utf32LittleEndianStart, allowedBy: .utf32BigEndian) == nil)
        #expect(ByteOrderMark.leading(utf32LittleEndianStart, allowedBy: .utf8) == nil)
        #expect(ByteOrderMark.leading(Data([0xFE, 0xFF, 0x00, 0x61]), allowedBy: .utf32) == nil)
    }

    @Test("A UTF-8 mark is left to Foundation, which drops it itself")
    func leavesTheUTF8MarkAlone() {
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("SELECT 1;".utf8)

        #expect(ByteOrderMark.leading(bytes) == nil)
        #expect(ByteOrderMark.leading(bytes, allowedBy: .utf8) == nil)
        #expect(String(data: bytes, encoding: .utf8) == "SELECT 1;")
    }

    @Test("Bytes too short for a mark carry none")
    func findsNoMarkInTooFewBytes() {
        #expect(ByteOrderMark.leading(Data()) == nil)
        #expect(ByteOrderMark.leading(Data([0xFF])) == nil)
        #expect(ByteOrderMark.leading(Data([0x00, 0x00, 0xFE])) == nil)
        #expect(ByteOrderMark.leading(Data("SELECT".utf8)) == nil)
    }
}
