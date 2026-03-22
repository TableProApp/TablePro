//
//  HexEditorTests.swift
//  TablePro

import Foundation
import Testing

@testable import TablePro

// swiftlint:disable force_unwrapping

@Suite("Hex Editor")
@MainActor
struct HexEditorTests {
    // MARK: - BlobFormattingService Round-Trip

    @Test("Format with .edit context then parse back returns original string")
    func editFormatRoundTrip() {
        let service = BlobFormattingService.shared
        let original = "Hello, World!"
        let formatted = service.format(original, for: .edit)
        #expect(formatted != nil)
        let parsed = service.parseHex(formatted!)
        #expect(parsed == original)
    }

    @Test("Format with .detail context produces hex dump format")
    func detailFormatProducesHexDump() {
        let service = BlobFormattingService.shared
        let formatted = service.format("Hello", for: .detail)
        #expect(formatted != nil)
        #expect(formatted!.contains("00000000"))
        #expect(formatted!.contains("|Hello|"))
    }

    @Test("Format with .grid context produces compact hex format")
    func gridFormatProducesCompactHex() {
        let service = BlobFormattingService.shared
        let formatted = service.format("Hello", for: .grid)
        #expect(formatted == "0x48656C6C6F")
    }

    @Test("Format with .copy context produces compact hex format")
    func copyFormatProducesCompactHex() {
        let service = BlobFormattingService.shared
        let formatted = service.format("Hello", for: .copy)
        #expect(formatted == "0x48656C6C6F")
    }

    // MARK: - parseHex Validation

    @Test("Parse valid space-separated hex bytes")
    func parseSpaceSeparatedHex() {
        let result = BlobFormattingService.shared.parseHex("48 65 6C 6C 6F")
        #expect(result == "Hello")
    }

    @Test("Parse valid continuous hex string")
    func parseContinuousHex() {
        let result = BlobFormattingService.shared.parseHex("48656C6C6F")
        #expect(result == "Hello")
    }

    @Test("Parse valid hex with 0x prefix")
    func parseHexWithLowercasePrefix() {
        let result = BlobFormattingService.shared.parseHex("0x48656C6C6F")
        #expect(result == "Hello")
    }

    @Test("Parse valid hex with 0X prefix")
    func parseHexWithUppercasePrefix() {
        let result = BlobFormattingService.shared.parseHex("0X48656C6C6F")
        #expect(result == "Hello")
    }

    @Test("Parse returns nil for odd number of hex characters")
    func parseRejectsOddLength() {
        let result = BlobFormattingService.shared.parseHex("48656C6C6")
        #expect(result == nil)
    }

    @Test("Parse returns nil for non-hex characters")
    func parseRejectsNonHexCharacters() {
        let result = BlobFormattingService.shared.parseHex("GHIJ")
        #expect(result == nil)
    }

    @Test("Parse returns nil for empty string")
    func parseRejectsEmptyString() {
        let result = BlobFormattingService.shared.parseHex("")
        #expect(result == nil)
    }

    @Test("Parse returns nil for whitespace-only string")
    func parseRejectsWhitespaceOnly() {
        let result = BlobFormattingService.shared.parseHex("   \t\n  ")
        #expect(result == nil)
    }

    @Test("Parse hex with mixed whitespace (tabs and newlines)")
    func parseHexWithMixedWhitespace() {
        let result = BlobFormattingService.shared.parseHex("48\t65\n6C 6C\t6F")
        #expect(result == "Hello")
    }

    // MARK: - String+HexDump Formatting

    @Test("formattedAsHexDump on Hello has address, hex bytes, and ASCII column")
    func hexDumpFormatStructure() {
        let dump = "Hello".formattedAsHexDump()
        #expect(dump != nil)
        #expect(dump!.contains("00000000"))
        #expect(dump!.contains("48 65 6C 6C 6F"))
        #expect(dump!.contains("|Hello|"))
    }

    @Test("formattedAsHexDump returns nil for empty string")
    func hexDumpReturnsNilForEmpty() {
        let dump = "".formattedAsHexDump()
        #expect(dump == nil)
    }

    @Test("formattedAsCompactHex on Hello returns 0x prefix with hex bytes")
    func compactHexFormat() {
        let hex = "Hello".formattedAsCompactHex()
        #expect(hex == "0x48656C6C6F")
    }

    @Test("formattedAsCompactHex returns nil for empty string")
    func compactHexReturnsNilForEmpty() {
        let hex = "".formattedAsCompactHex()
        #expect(hex == nil)
    }

    @Test("formattedAsEditableHex on Hello returns space-separated hex bytes")
    func editableHexFormat() {
        let hex = "Hello".formattedAsEditableHex()
        #expect(hex == "48 65 6C 6C 6F")
    }

    @Test("formattedAsEditableHex returns nil for empty string")
    func editableHexReturnsNilForEmpty() {
        let hex = "".formattedAsEditableHex()
        #expect(hex == nil)
    }

    @Test("formattedAsHexDump truncates data exceeding maxBytes")
    func hexDumpTruncation() {
        let longString = String(repeating: "A", count: 100)
        let dump = longString.formattedAsHexDump(maxBytes: 32)
        #expect(dump != nil)
        #expect(dump!.contains("truncated"))
        #expect(dump!.contains("100 bytes total"))
    }

    @Test("formattedAsEditableHex truncates data exceeding maxBytes")
    func editableHexTruncation() {
        let longString = String(repeating: "B", count: 100)
        let hex = longString.formattedAsEditableHex(maxBytes: 32)
        #expect(hex != nil)
        #expect(hex!.hasSuffix("…"))
    }

    @Test("formattedAsCompactHex truncates data exceeding maxBytes")
    func compactHexTruncation() {
        let longString = String(repeating: "C", count: 100)
        let hex = longString.formattedAsCompactHex(maxBytes: 32)
        #expect(hex != nil)
        #expect(hex!.hasSuffix("…"))
    }

    // MARK: - Binary Data Preservation (ISO-Latin1 Round-Trip)

    @Test("All 256 byte values survive ISO-Latin1 encoding round-trip")
    func fullByteRangeRoundTrip() {
        let service = BlobFormattingService.shared
        let allBytes = Data(0 ... 255)
        let original = String(data: allBytes, encoding: .isoLatin1)!

        let formatted = service.format(original, for: .edit)
        #expect(formatted != nil)

        let parsed = service.parseHex(formatted!)
        #expect(parsed != nil)

        let originalBytes = [UInt8](original.data(using: .isoLatin1)!)
        let parsedBytes = [UInt8](parsed!.data(using: .isoLatin1)!)
        #expect(originalBytes == parsedBytes)
    }

    @Test("String with null bytes survives round-trip")
    func nullBytesRoundTrip() {
        let service = BlobFormattingService.shared
        let data = Data([0x00, 0x41, 0x00, 0x42, 0x00])
        let original = String(data: data, encoding: .isoLatin1)!

        let formatted = service.format(original, for: .edit)
        #expect(formatted != nil)

        let parsed = service.parseHex(formatted!)
        #expect(parsed != nil)

        let parsedBytes = [UInt8](parsed!.data(using: .isoLatin1)!)
        #expect(parsedBytes == [0x00, 0x41, 0x00, 0x42, 0x00])
    }

    @Test("String with high bytes (0x80-0xFF) survives round-trip")
    func highBytesRoundTrip() {
        let service = BlobFormattingService.shared
        let highBytes = Data(0x80 ... 0xFF)
        let original = String(data: highBytes, encoding: .isoLatin1)!

        let formatted = service.format(original, for: .edit)
        #expect(formatted != nil)

        let parsed = service.parseHex(formatted!)
        #expect(parsed != nil)

        let originalBytes = [UInt8](original.data(using: .isoLatin1)!)
        let parsedBytes = [UInt8](parsed!.data(using: .isoLatin1)!)
        #expect(originalBytes == parsedBytes)
    }

    // MARK: - Edge Cases

    @Test("Format returns nil for empty string input")
    func formatReturnsNilForEmptyString() {
        let service = BlobFormattingService.shared
        #expect(service.format("", for: .grid) == nil)
        #expect(service.format("", for: .detail) == nil)
        #expect(service.format("", for: .edit) == nil)
    }

    @Test("Large data truncation works correctly with default maxBytes")
    func largeDataTruncation() {
        let largeString = String(repeating: "X", count: 20_000)
        let dump = largeString.formattedAsHexDump()
        #expect(dump != nil)
        #expect(dump!.contains("truncated"))
        #expect(dump!.contains("bytes total"))
    }

    @Test("Hex dump with exactly 16 bytes fills one complete line")
    func hexDumpSingleCompleteLine() {
        let sixteenBytes = "0123456789ABCDEF"
        let dump = sixteenBytes.formattedAsHexDump()
        #expect(dump != nil)
        let lines = dump!.split(separator: "\n")
        #expect(lines.count == 1)
        #expect(dump!.contains("|0123456789ABCDEF|"))
    }

    @Test("Hex dump with 17 bytes spans two lines")
    func hexDumpTwoLines() {
        let seventeenBytes = "0123456789ABCDEFG"
        let dump = seventeenBytes.formattedAsHexDump()
        #expect(dump != nil)
        let lines = dump!.split(separator: "\n")
        #expect(lines.count == 2)
    }

    @Test("Parse hex with 0x prefix and spaces combined")
    func parseHexPrefixWithSpaces() {
        let result = BlobFormattingService.shared.parseHex("0x48 65 6C 6C 6F")
        #expect(result == "Hello")
    }

    @Test("formattedAsEditableHex then parseHex round-trip for single byte")
    func singleByteRoundTrip() {
        let service = BlobFormattingService.shared
        let data = Data([0xFF])
        let original = String(data: data, encoding: .isoLatin1)!
        let formatted = original.formattedAsEditableHex()
        #expect(formatted == "FF")
        let parsed = service.parseHex(formatted!)
        #expect(parsed == original)
    }

    @Test("parseHex rejects truncated hex string ending with ellipsis")
    func parseRejectsTruncatedHex() {
        let result = BlobFormattingService.shared.parseHex("48 65 6C …")
        #expect(result == nil)
    }

    @Test("formattedAsEditableHex returns truncated string with ellipsis for large data")
    func editableHexTruncationHasEllipsis() {
        let largeString = String(repeating: "X", count: 20_000)
        let hex = largeString.formattedAsEditableHex()
        #expect(hex != nil)
        #expect(hex!.hasSuffix("…"))
        #expect(BlobFormattingService.shared.parseHex(hex!) == nil)
    }
}

// swiftlint:enable force_unwrapping
