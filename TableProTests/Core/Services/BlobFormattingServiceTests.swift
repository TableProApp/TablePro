//
//  BlobFormattingServiceTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("BlobFormattingService - compact hex (grid context)")
@MainActor
struct BlobFormattingServiceCompactHexTests {
    @Test("Issue #1188 exact value renders as 0xD38CE566...534F")
    func issue1188CompactHex() {
        // Bridge encodes the 48 raw bytes as isoLatin1 String (one char per byte)
        let bytes = Data([
            0xD3, 0x8C, 0xE5, 0x66, 0xB9, 0x67, 0x52, 0x0C,
            0xAF, 0x46, 0x17, 0x47, 0xAB, 0xC7, 0x7D, 0x27,
            0x5F, 0x08, 0x4F, 0x60, 0x16, 0x97, 0xD1, 0xEA,
            0x13, 0x5B, 0x03, 0x61, 0xCA, 0xBB, 0x53, 0x4F,
            0x70, 0x22, 0x02, 0xB9, 0x52, 0xE0, 0x04, 0x47,
            0xB6, 0x75, 0x68, 0x7A, 0xF8, 0xF5, 0xD4, 0x3B
        ])
        let value = String(data: bytes, encoding: .isoLatin1) ?? ""

        let result = value.formattedAsCompactHex()

        let expected = "0xD38CE566B967520CAF461747ABC77D275F084F601697D1EA135B0361CABB534F702202B952E00447B675687AF8F5D43B"
        #expect(result == expected)
    }

    @Test("Empty string returns nil")
    func emptyString() {
        #expect("".formattedAsCompactHex() == nil)
    }

    @Test("Single 0x00 byte renders as 0x00")
    func singleZeroByte() {
        let value = String(data: Data([0x00]), encoding: .isoLatin1) ?? ""
        #expect(value.formattedAsCompactHex() == "0x00")
    }

    @Test("Embedded NUL byte preserved in hex output")
    func embeddedNulByte() {
        let value = String(data: Data([0x48, 0x00, 0x69]), encoding: .isoLatin1) ?? ""
        #expect(value.formattedAsCompactHex() == "0x480069")
    }

    @Test("Truncates with ellipsis when over maxBytes")
    func truncates() {
        let bytes = Data(repeating: 0xAB, count: 100)
        let value = String(data: bytes, encoding: .isoLatin1) ?? ""
        let result = value.formattedAsCompactHex(maxBytes: 64)
        #expect(result?.hasSuffix("…") == true)
        // 0x + 64 bytes * 2 hex chars + ellipsis = 131 chars
        #expect((result as NSString?)?.length == 131)
    }
}

@Suite("BlobFormattingService - byte count")
@MainActor
struct BlobFormattingServiceByteCountTests {
    @Test("Issue #1188 exact value reports 48 bytes (not 98)")
    func issue1188ByteCount() {
        let bytes = Data([
            0xD3, 0x8C, 0xE5, 0x66, 0xB9, 0x67, 0x52, 0x0C,
            0xAF, 0x46, 0x17, 0x47, 0xAB, 0xC7, 0x7D, 0x27,
            0x5F, 0x08, 0x4F, 0x60, 0x16, 0x97, 0xD1, 0xEA,
            0x13, 0x5B, 0x03, 0x61, 0xCA, 0xBB, 0x53, 0x4F,
            0x70, 0x22, 0x02, 0xB9, 0x52, 0xE0, 0x04, 0x47,
            0xB6, 0x75, 0x68, 0x7A, 0xF8, 0xF5, 0xD4, 0x3B
        ])
        let value = String(data: bytes, encoding: .isoLatin1) ?? ""

        // The HexEditorContentView byteCount math: value.data(using: .isoLatin1)?.count
        let count = value.data(using: .isoLatin1)?.count

        #expect(count == 48)
        // Pre-fix bug: would have been 98 (length of "\\xd38ce566..." escape string)
        #expect(count != 98)
    }
}

@Suite("BlobFormattingService - hex dump (detail context)")
@MainActor
struct BlobFormattingServiceHexDumpTests {
    @Test("Issue #1188 first 16 bytes match expected hex dump line")
    func issue1188FirstLine() {
        let bytes = Data([
            0xD3, 0x8C, 0xE5, 0x66, 0xB9, 0x67, 0x52, 0x0C,
            0xAF, 0x46, 0x17, 0x47, 0xAB, 0xC7, 0x7D, 0x27,
            0x5F, 0x08, 0x4F, 0x60, 0x16, 0x97, 0xD1, 0xEA,
            0x13, 0x5B, 0x03, 0x61, 0xCA, 0xBB, 0x53, 0x4F,
            0x70, 0x22, 0x02, 0xB9, 0x52, 0xE0, 0x04, 0x47,
            0xB6, 0x75, 0x68, 0x7A, 0xF8, 0xF5, 0xD4, 0x3B
        ])
        let value = String(data: bytes, encoding: .isoLatin1) ?? ""

        guard let dump = value.formattedAsHexDump() else {
            Issue.record("Hex dump returned nil")
            return
        }

        // Format per spec: 8-char offset, 16 hex bytes split into two groups of 8, ASCII column
        let firstLine = dump.split(separator: "\n").first.map(String.init)
        #expect(firstLine?.hasPrefix("00000000  D3 8C E5 66 B9 67 52 0C  AF 46 17 47 AB C7 7D 27") == true)
    }

    @Test("Empty input returns nil")
    func emptyInput() {
        #expect("".formattedAsHexDump() == nil)
    }
}

@Suite("BlobFormattingService - editable hex (edit context)")
@MainActor
struct BlobFormattingServiceEditableHexTests {
    @Test("Issue #1188 produces space-separated hex bytes")
    func issue1188Editable() {
        let bytes = Data([
            0xD3, 0x8C, 0xE5, 0x66, 0xB9, 0x67, 0x52, 0x0C,
            0xAF, 0x46, 0x17, 0x47, 0xAB, 0xC7, 0x7D, 0x27,
            0x5F, 0x08, 0x4F, 0x60, 0x16, 0x97, 0xD1, 0xEA,
            0x13, 0x5B, 0x03, 0x61, 0xCA, 0xBB, 0x53, 0x4F,
            0x70, 0x22, 0x02, 0xB9, 0x52, 0xE0, 0x04, 0x47,
            0xB6, 0x75, 0x68, 0x7A, 0xF8, 0xF5, 0xD4, 0x3B
        ])
        let value = String(data: bytes, encoding: .isoLatin1) ?? ""

        guard let editable = value.formattedAsEditableHex() else {
            Issue.record("Editable hex returned nil")
            return
        }

        let pairs = editable.split(separator: " ").map(String.init)
        #expect(pairs.count == 48)
        #expect(pairs.first == "D3")
        #expect(pairs.last == "3B")
    }
}

@Suite("BlobFormattingService - parseHex round-trip")
@MainActor
struct BlobFormattingServiceParseHexTests {
    @Test("parseHex round-trips issue #1188 bytes via isoLatin1")
    func issue1188RoundTrip() {
        let bytes = Data([
            0xD3, 0x8C, 0xE5, 0x66, 0xB9, 0x67, 0x52, 0x0C,
            0xAF, 0x46, 0x17, 0x47, 0xAB, 0xC7, 0x7D, 0x27,
            0x5F, 0x08, 0x4F, 0x60, 0x16, 0x97, 0xD1, 0xEA,
            0x13, 0x5B, 0x03, 0x61, 0xCA, 0xBB, 0x53, 0x4F,
            0x70, 0x22, 0x02, 0xB9, 0x52, 0xE0, 0x04, 0x47,
            0xB6, 0x75, 0x68, 0x7A, 0xF8, 0xF5, 0xD4, 0x3B
        ])
        let editableHex = "D3 8C E5 66 B9 67 52 0C AF 46 17 47 AB C7 7D 27 5F 08 4F 60 16 97 D1 EA 13 5B 03 61 CA BB 53 4F 70 22 02 B9 52 E0 04 47 B6 75 68 7A F8 F5 D4 3B"

        guard let parsed = BlobFormattingService.shared.parseHex(editableHex) else {
            Issue.record("parseHex returned nil")
            return
        }

        // Round-trip through isoLatin1 String back to Data must match exactly
        #expect(parsed.data(using: .isoLatin1) == bytes)
    }

    @Test("parseHex accepts 0x prefix")
    func acceptsPrefix() {
        let result = BlobFormattingService.shared.parseHex("0xDEADBEEF")
        #expect(result?.data(using: .isoLatin1) == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test("parseHex rejects odd-length input")
    func rejectsOddLength() {
        #expect(BlobFormattingService.shared.parseHex("ABC") == nil)
    }

    @Test("parseHex rejects non-hex characters")
    func rejectsNonHex() {
        #expect(BlobFormattingService.shared.parseHex("XYZW") == nil)
    }
}
