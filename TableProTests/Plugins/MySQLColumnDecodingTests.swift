//
//  MySQLColumnDecodingTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct MySQLColumnDecodingTests {
    private static let doubleEncodedMail = String(bytes: [0xC3, 0xA3, 0xC6, 0x92, 0xC2, 0xA1], encoding: .utf8) ?? ""
    private static let koreanComment: [UInt8] = [0xEA, 0xB3, 0x84, 0xEC, 0xA0, 0x95, 0x20, 0xEA, 0xB5, 0xAC, 0xEB, 0xB6, 0x84]

    private func decoding(type: UInt32, charset: UInt32, name: String? = "utf8mb4") -> MySQLColumnDecoding {
        MySQLColumnDecoding(typeRaw: type, charsetnr: charset, characterSetName: name)
    }

    private func decode(
        _ bytes: [UInt8],
        with decoding: MySQLColumnDecoding,
        encoding: MySQLConnectionEncoding = .utf8
    ) -> PluginCellValue {
        bytes.withUnsafeBytes { decoding.decode($0, encoding: encoding) }
    }

    @Test("Each column kind gets its own decoding")
    func columnKinds() {
        #expect(decoding(type: 255, charset: 63) == .geometry)
        #expect(decoding(type: 16, charset: 63) == .bit)
        #expect(decoding(type: 252, charset: 63) == .bytes)
        #expect(decoding(type: 253, charset: 63) == .bytes)
        #expect(decoding(type: 253, charset: 8, name: "latin1") == .text(.latin1))
        #expect(decoding(type: 252, charset: 255, name: "utf8mb4") == .text(.utf8mb4))
    }

    @Test("Numbers, dates and JSON carry the binary charset and decode as text")
    func binaryCharsetScalarsAreText() {
        for type: UInt32 in [3, 8, 12, 245, 246] {
            #expect(decoding(type: type, charset: 63, name: "binary") == .text(.utf8mb4))
        }
    }

    @Test("Databend's booleans, hex-encoded binary and text geometry keep their own decoding")
    func databendShapes() {
        let boolean = MySQLColumnDecoding(typeRaw: 2, length: 1, charsetnr: 63, characterSetName: "binary", flavor: .databend)
        #expect(boolean == .databendBoolean)
        #expect(decode(Array("1".utf8), with: boolean) == .text("true"))

        let binary = MySQLColumnDecoding(typeRaw: 252, charsetnr: 63, characterSetName: "binary", flavor: .databend)
        #expect(binary == .databendHexBytes)
        #expect(decode(Array("CAFE".utf8), with: binary) == .bytes(Data([0xCA, 0xFE])))

        let geometry = MySQLColumnDecoding(typeRaw: 255, charsetnr: 63, characterSetName: "binary", flavor: .databend)
        #expect(geometry == .text(.utf8mb4))
        #expect(MySQLColumnDecoding(typeRaw: 2, length: 1, charsetnr: 63, characterSetName: "binary") == .text(.utf8mb4))
    }

    @Test("A collation id libmariadb does not know decodes as the session's UTF-8")
    func unknownCollationIsUTF8() {
        #expect(decoding(type: 253, charset: 309, name: nil) == .text(.utf8mb4))
    }

    @Test("The default encoding shows exactly what the server stored")
    func defaultShowsStoredText() {
        let stored = Array(Self.doubleEncodedMail.utf8)
        #expect(decode(stored, with: .text(.utf8mb4)) == .text(Self.doubleEncodedMail))
    }

    @Test("UTF-8 via Latin 1 repairs text columns only")
    func legacyModeRepairsText() {
        let stored = Array(Self.doubleEncodedMail.utf8)
        #expect(decode(stored, with: .text(.utf8mb4), encoding: .utf8ViaLatin1) == .text("メ"))
        #expect(decode(stored, with: .bytes, encoding: .utf8ViaLatin1) == .bytes(Data(stored)))
    }

    @Test("A result row keeps NULLs and decodes every other cell by its column")
    func resultRow() {
        var columns = MySQLResultColumns()
        columns.append(name: "id", typeCode: 3, typeName: "INT", decoding: .text(.utf8mb4), flags: mysqlPriKeyFlag)
        columns.append(name: "note", typeCode: 253, typeName: "VARCHAR", decoding: .text(.latin1), flags: 0)
        columns.append(name: "missing", typeCode: 253, typeName: "VARCHAR", decoding: .text(.utf8mb4), flags: 0)
        let cells: [[UInt8]?] = [Array("7".utf8), [0x63, 0x61, 0x66, 0xE9], nil]
        let buffers = cells.map { cell in
            cell.map { bytes in
                let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: bytes.count, alignment: 1)
                buffer.copyBytes(from: bytes)
                return buffer
            }
        }
        defer { buffers.forEach { $0?.deallocate() } }

        let row = columns.row(encoding: .utf8) { index in
            buffers[index].map { UnsafeRawBufferPointer($0) }
        }

        #expect(row == [.text("7"), .text("café"), .null])
        #expect(columns.metadata.first?.isPrimaryKey == true)
    }

    /// Measured on 4.1.22: every string column of `SHOW TABLE STATUS` is charset 63 with `BINARY_FLAG`,
    /// and the Korean comment `계정 구분` arrives as these UTF-8 bytes.
    @Test("A binary-labelled string reads as text when the statement asks for it")
    func binaryLabelledShowText() {
        for type: UInt32 in [253, 254] {
            let flagged = MySQLColumnDecoding(typeRaw: type, charsetnr: 63, characterSetName: "binary", binaryStringsAreText: true)
            #expect(flagged == .utf8TextOrBytes, "type \(type)")
        }
        #expect(decode(Self.koreanComment, with: .utf8TextOrBytes) == .text("계정 구분"))
    }

    @Test("A binary-labelled string that is not UTF-8 stays bytes")
    func invalidUTF8StaysBytes() {
        let eucKR: [UInt8] = [0xC5, 0xD7, 0xC0, 0xCC, 0xBA, 0xED]
        #expect(decode(eucKR, with: .utf8TextOrBytes) == .bytes(Data(eucKR)))
    }

    @Test("UTF-8 via Latin 1 repairs a binary-labelled string read as text")
    func legacyModeRepairsBinaryLabelledText() {
        let stored = Array(Self.doubleEncodedMail.utf8)
        #expect(decode(stored, with: .utf8TextOrBytes, encoding: .utf8ViaLatin1) == .text("メ"))
    }

    @Test("Without the flag a binary string stays bytes")
    func unflaggedBinaryStringIsBytes() {
        let unflagged = MySQLColumnDecoding(typeRaw: 253, charsetnr: 63, characterSetName: "binary", binaryStringsAreText: false)
        #expect(unflagged == .bytes)
        #expect(decode(Self.koreanComment, with: unflagged) == .bytes(Data(Self.koreanComment)))
    }

    @Test("The flag leaves a blob, a text column and a number as they were")
    func flagReachesOnlyBinaryStrings() {
        func flagged(type: UInt32, charset: UInt32, name: String) -> MySQLColumnDecoding {
            MySQLColumnDecoding(typeRaw: type, charsetnr: charset, characterSetName: name, binaryStringsAreText: true)
        }

        #expect(flagged(type: 252, charset: 63, name: "binary") == .bytes)
        #expect(flagged(type: 253, charset: 33, name: "utf8") == .text(MySQLCharacterSet(serverName: "utf8")))
        #expect(flagged(type: 8, charset: 63, name: "binary") == .text(.utf8mb4))
    }

    @Test("Names and messages read as UTF-8, or as MySQL latin1 when a latin1 session sent them")
    func sessionText() {
        let utf8 = Array("列名".utf8)
        let latin1: [UInt8] = [0x63, 0x61, 0x66, 0xE9]
        #expect(utf8.withUnsafeBytes { mysqlSessionText($0, encoding: .utf8) } == "列名")
        #expect(latin1.withUnsafeBytes { mysqlSessionText($0, encoding: .utf8) } == "café")
    }
}
