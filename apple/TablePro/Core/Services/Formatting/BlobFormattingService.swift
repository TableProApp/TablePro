//
//  BlobFormattingService.swift
//  TablePro
//
//  Centralized BLOB formatting service for binary data display.
//

import Foundation
import TableProPluginKit

enum BlobDisplayContext {
    case grid
    case detail
    case copy
    case edit
}

final class BlobFormattingService: Sendable {
    static let shared = BlobFormattingService()

    private init() {}

    func format(_ value: String, for context: BlobDisplayContext) -> String? {
        switch context {
        case .grid:
            return value.formattedAsCompactHex()
        case .copy:
            return value.formattedAsCompactHex(maxBytes: .max)
        case .detail:
            return value.formattedAsHexDump()
        case .edit:
            return value.formattedAsEditableHex()
        }
    }

    func format(_ data: Data, for context: BlobDisplayContext) -> String? {
        let value = String(data: data, encoding: .isoLatin1) ?? ""
        return format(value, for: context)
    }

    func parseHex(_ hexString: String) -> String? {
        var cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("0x") || cleaned.hasPrefix("0X") {
            cleaned = String(cleaned.dropFirst(2))
        }
        cleaned = cleaned.replacingOccurrences(of: " ", with: "", options: .literal)
        cleaned = cleaned.replacingOccurrences(of: "\n", with: "", options: .literal)
        cleaned = cleaned.replacingOccurrences(of: "\t", with: "", options: .literal)

        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)

        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            let byteString = cleaned[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            bytes.append(byte)
            index = nextIndex
        }

        let data = Data(bytes)
        return String(data: data, encoding: .isoLatin1)
    }

    static func hasHexPrefix(_ text: String) -> Bool {
        text.hasPrefix("0x") || text.hasPrefix("0X")
    }

    // The form a copy, a CSV export and an XLSX export write bytes in, read strictly: a copy cut short with `…`
    // or text that only starts like hex is not bytes.
    func bytes(fromPrefixedHex text: String) -> Data? {
        guard Self.hasHexPrefix(text) else { return nil }
        let digits = text.utf8.dropFirst(2)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        var high: UInt8?
        for character in digits {
            guard let nibble = Self.nibble(character) else { return nil }
            if let pending = high {
                bytes.append(pending << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        return Data(bytes)
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return character - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    func requiresFormatting(columnType: ColumnType) -> Bool {
        columnType.isBlobType
    }

    func formatIfNeeded(_ value: String, columnType: ColumnType?, for context: BlobDisplayContext) -> String {
        guard let columnType, requiresFormatting(columnType: columnType) else {
            return value
        }
        return format(value, for: context) ?? value
    }
}
