//
//  StringHexDumpTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("String+HexDump")
struct StringHexDumpTests {
    // MARK: - Hex Dump

    @Test("Empty string returns nil")
    func emptyStringReturnsNil() {
        #expect("".formattedAsHexDump() == nil)
    }

    @Test("Basic ASCII produces correct hex and ASCII column")
    func basicASCII() {
        let result = "Hello".formattedAsHexDump()
        #expect(result != nil)
        #expect(result?.contains("48 65 6C 6C 6F") == true)
        #expect(result?.contains("|Hello|") == true)
    }

    @Test("Full 16-byte line has correct offset and ASCII")
    func fullLine() {
        let result = "0123456789ABCDEF".formattedAsHexDump()
        #expect(result?.hasPrefix("00000000") == true)
        #expect(result?.contains("|0123456789ABCDEF|") == true)
    }

    @Test("Multiple lines have correct offsets")
    func multipleLines() {
        let result = "ABCDEFGHIJKLMNOPQRST".formattedAsHexDump()
        let lines = result?.split(separator: "\n") ?? []
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("00000000"))
        #expect(lines[1].hasPrefix("00000010"))
    }

    @Test("Non-printable characters show as dots in ASCII column")
    func nonPrintableCharsShowAsDots() {
        let bytes: [UInt8] = [0x00, 0x01, 0x02, 0x41, 0x42, 0x7F, 0xFF]
        guard let input = String(bytes: bytes, encoding: .isoLatin1) else {
            Issue.record("Failed to create isoLatin1 string")
            return
        }
        let result = input.formattedAsHexDump()
        #expect(result?.contains("|...AB..|") == true)
    }

    @Test("Truncation adds summary line")
    func truncation() {
        let input = String(repeating: "A", count: 100)
        let result = input.formattedAsHexDump(maxBytes: 32)
        #expect(result?.contains("truncated") == true)
        #expect(result?.contains("100 bytes total") == true)
        let lines = result?.split(separator: "\n") ?? []
        #expect(lines.count == 3)
    }

    @Test("Offset formatting across multiple lines")
    func offsetFormatting() {
        let input = String(repeating: "X", count: 48)
        let lines = input.formattedAsHexDump()?.split(separator: "\n") ?? []
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("00000000"))
        #expect(lines[1].hasPrefix("00000010"))
        #expect(lines[2].hasPrefix("00000020"))
    }

    @Test("Single byte")
    func singleByte() {
        let result = "A".formattedAsHexDump()
        #expect(result?.contains("41") == true)
        #expect(result?.contains("|A|") == true)
    }

    // MARK: - Compact Hex

    @Test("Compact hex basic ASCII")
    func compactHexBasic() {
        #expect("Hello".formattedAsCompactHex() == "0x48656C6C6F")
    }

    @Test("Compact hex empty string returns nil")
    func compactHexEmpty() {
        #expect("".formattedAsCompactHex() == nil)
    }

    @Test("Compact hex truncation adds ellipsis")
    func compactHexTruncation() {
        let input = String(repeating: "A", count: 100)
        #expect(input.formattedAsCompactHex(maxBytes: 4) == "0x41414141…")
    }

    @Test("Compact hex non-printable bytes")
    func compactHexNonPrintable() {
        let bytes: [UInt8] = [0x00, 0xFF]
        guard let input = String(bytes: bytes, encoding: .isoLatin1) else {
            Issue.record("Failed to create isoLatin1 string")
            return
        }
        #expect(input.formattedAsCompactHex() == "0x00FF")
    }

    // MARK: - Editable Hex

    @Test("Editable hex basic ASCII")
    func editableHexBasic() {
        #expect("Hello".formattedAsEditableHex() == "48 65 6C 6C 6F")
    }

    @Test("Editable hex empty string returns nil")
    func editableHexEmpty() {
        #expect("".formattedAsEditableHex() == nil)
    }

    @Test("Editable hex non-printable bytes")
    func editableHexNonPrintable() {
        let bytes: [UInt8] = [0x00, 0x01, 0xFF]
        guard let input = String(bytes: bytes, encoding: .isoLatin1) else {
            Issue.record("Failed to create isoLatin1 string")
            return
        }
        #expect(input.formattedAsEditableHex() == "00 01 FF")
    }

    @Test("Editable hex truncation adds ellipsis")
    func editableHexTruncation() {
        let input = String(repeating: "A", count: 100)
        let result = input.formattedAsEditableHex(maxBytes: 3)
        #expect(result?.hasPrefix("41 41 41") == true)
        #expect(result?.hasSuffix("…") == true)
    }

    // MARK: - Parse Hex

    @Test("Parse space-separated hex")
    @MainActor
    func parseHexSpaceSeparated() {
        #expect(BlobFormattingService.shared.parseHex("48 65 6C 6C 6F") == "Hello")
    }

    @Test("Parse continuous hex")
    @MainActor
    func parseHexContinuous() {
        #expect(BlobFormattingService.shared.parseHex("48656C6C6F") == "Hello")
    }

    @Test("Parse hex with 0x prefix")
    @MainActor
    func parseHexWithPrefix() {
        #expect(BlobFormattingService.shared.parseHex("0x48656C6C6F") == "Hello")
    }

    @Test("Parse hex rejects odd-length input")
    @MainActor
    func parseHexInvalidOddLength() {
        #expect(BlobFormattingService.shared.parseHex("486") == nil)
    }

    @Test("Parse hex rejects invalid characters")
    @MainActor
    func parseHexInvalidChars() {
        #expect(BlobFormattingService.shared.parseHex("ZZZZ") == nil)
    }

    @Test("Parse hex rejects empty string")
    @MainActor
    func parseHexEmpty() {
        #expect(BlobFormattingService.shared.parseHex("") == nil)
    }

    @Test("Round-trip: raw → editable hex → parse back to raw")
    @MainActor
    func parseHexRoundTrip() {
        let bytes: [UInt8] = [0x00, 0x01, 0x7F, 0x80, 0xFF]
        guard let original = String(bytes: bytes, encoding: .isoLatin1),
              let hex = original.formattedAsEditableHex(),
              let roundTripped = BlobFormattingService.shared.parseHex(hex) else {
            Issue.record("Round-trip conversion failed")
            return
        }
        #expect(roundTripped == original)
    }
}
