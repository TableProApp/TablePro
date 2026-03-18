//
//  BlobFormattingService.swift
//  TablePro
//
//  Centralized BLOB formatting service for binary data display.
//

import Foundation

/// Display context for BLOB formatting.
enum BlobDisplayContext {
    /// Data grid cell: compact single-line "0x48656C6C6F..."
    case grid
    /// Sidebar detail view: full multi-line hex dump
    case detail
    /// Copy to clipboard: compact hex
    case copy
    /// Editable hex in sidebar: space-separated hex bytes "48 65 6C 6C 6F"
    case edit
}

@MainActor
final class BlobFormattingService {
    static let shared = BlobFormattingService()

    private init() {}

    /// Format a raw BLOB string value for the given display context.
    func format(_ value: String, for context: BlobDisplayContext) -> String? {
        switch context {
        case .grid, .copy:
            return value.formattedAsCompactHex()
        case .detail:
            return value.formattedAsHexDump()
        case .edit:
            return value.formattedAsEditableHex()
        }
    }

    /// Parse an edited hex string back to a raw binary string.
    /// Accepts space-separated hex bytes (e.g., "48 65 6C 6C 6F") or continuous hex (e.g., "48656C6C6F").
    /// Returns nil if the hex string is invalid.
    func parseHex(_ hexString: String) -> String? {
        var cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("0x") || cleaned.hasPrefix("0X") {
            cleaned = String(cleaned.dropFirst(2))
        }
        cleaned = cleaned.replacingOccurrences(of: " ", with: "")
        cleaned = cleaned.replacingOccurrences(of: "\n", with: "")
        cleaned = cleaned.replacingOccurrences(of: "\t", with: "")

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

    /// Whether the given column type requires BLOB formatting.
    func requiresFormatting(columnType: ColumnType) -> Bool {
        columnType.isBlobType
    }

    /// Format a value if the column type is a BLOB type; otherwise return the original value.
    func formatIfNeeded(_ value: String, columnType: ColumnType?, for context: BlobDisplayContext) -> String {
        guard let columnType, requiresFormatting(columnType: columnType) else {
            return value
        }
        return format(value, for: context) ?? value
    }
}
