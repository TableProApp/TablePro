//
//  CellDisplayFormatterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("CellDisplayFormatter")
@MainActor
struct CellDisplayFormatterTests {
    @Test("nil input returns nil")
    func nilInput() {
        let result = CellDisplayFormatter.format(nil, columnType: nil)
        #expect(result == nil)
    }

    @Test("empty string returns empty")
    func emptyString() {
        let result = CellDisplayFormatter.format(.text(""), columnType: nil)
        #expect(result == "")
    }

    @Test("text value keeps a format the column cannot take")
    func textRejectsInapplicableFormat() {
        let result = CellDisplayFormatter.format(
            .text("1000000"),
            columnType: .text(rawType: "TEXT"),
            displayFormat: .unixTimestamp
        )

        #expect(result == "1000000")
    }

    @Test("MongoDB binary decoded as text stays out of the UUID format")
    func mongoTextBlobKeepsDriverEncoding() {
        let hex = "aabbccddaabbccddaabbccddaabbccdd"
        let withoutFormat = CellDisplayFormatter.format(
            .text(hex),
            columnType: .blob(rawType: "BinData"),
            databaseType: .mongodb
        )
        let result = CellDisplayFormatter.format(
            .text(hex),
            columnType: .blob(rawType: "BinData"),
            displayFormat: .uuid,
            databaseType: .mongodb
        )

        #expect(result == withoutFormat)
        #expect(result != ValueDisplayFormatService.applyFormat(hex, format: .uuid))
    }

    @Test("plain text passes through unchanged")
    func plainTextPassthrough() {
        let result = CellDisplayFormatter.format(.text("hello world"), columnType: nil)
        #expect(result == "hello world")
    }

    @Test("text with linebreaks is sanitized")
    func linebreaksSanitized() {
        let result = CellDisplayFormatter.format(.text("line1\nline2\rline3"), columnType: nil)
        #expect(result == "line1 line2 line3")
    }

    @Test("text over max length is truncated")
    func longTextTruncated() {
        let longString = String(repeating: "a", count: CellDisplayFormatter.maxDisplayLength + 100)
        let result = CellDisplayFormatter.format(.text(longString), columnType: nil)
        let expected = String(repeating: "a", count: CellDisplayFormatter.maxDisplayLength) + "…"
        #expect(result == expected)
    }

    @Test("text at max length is not truncated")
    func exactMaxLengthNotTruncated() {
        let exactString = String(repeating: "b", count: CellDisplayFormatter.maxDisplayLength)
        let result = CellDisplayFormatter.format(.text(exactString), columnType: nil)
        #expect(result == exactString)
    }

    @Test("nil column type skips type-specific formatting")
    func nilColumnType() {
        let result = CellDisplayFormatter.format(.text("2024-01-01"), columnType: nil)
        #expect(result == "2024-01-01")
    }

    @Test("UUID display format renders sixteen binary bytes")
    func binaryUuidDisplayFormat() {
        let data = Data([
            0xAF, 0x49, 0x45, 0x3B, 0x7F, 0x2F, 0xFB, 0x58,
            0xFC, 0xD3, 0x2B, 0xD3, 0x99, 0x59, 0x9F, 0xA5,
        ])

        let result = CellDisplayFormatter.format(
            .bytes(data),
            columnType: .blob(rawType: "BLOB"),
            displayFormat: .uuid
        )

        #expect(result == "af49453b-7f2f-fb58-fcd3-2bd399599fa5")
    }

    @Test("MongoDB binary UUIDs remain encoded until the driver decodes their subtype")
    func mongoBinaryUuidRequiresDriverDecoding() {
        let javaLegacyBytes = Data([
            0x24, 0x43, 0x25, 0x4A, 0xEB, 0x03, 0xD0, 0x8C,
            0x1A, 0x0D, 0xDA, 0xE2, 0xFC, 0x88, 0x32, 0x93,
        ])

        let result = CellDisplayFormatter.format(
            .bytes(javaLegacyBytes),
            columnType: .blob(rawType: "BLOB(3)"),
            displayFormat: .uuid,
            databaseType: .mongodb
        )

        #expect(result == "0x2443254AEB03D08C1A0DDAE2FC883293")
    }

    @Test("raw display format keeps binary bytes as hex")
    func rawBinaryDisplayFormat() {
        let data = Data([0xAF, 0x49, 0x45, 0x3B])

        let implicitRaw = CellDisplayFormatter.format(
            .bytes(data),
            columnType: .blob(rawType: "BLOB")
        )
        let explicitRaw = CellDisplayFormatter.format(
            .bytes(data),
            columnType: .blob(rawType: "BLOB"),
            displayFormat: .raw
        )

        #expect(implicitRaw == "0xAF49453B")
        #expect(explicitRaw == "0xAF49453B")
    }

    @Test("UUID display format does not reinterpret other binary lengths")
    func invalidBinaryUuidLength() {
        for count in [15, 17] {
            let data = Data(repeating: 0xAB, count: count)
            let result = CellDisplayFormatter.format(
                .bytes(data),
                columnType: .blob(rawType: "BLOB"),
                displayFormat: .uuid
            )

            #expect(result == "0x" + String(repeating: "AB", count: count))
        }
    }
}
