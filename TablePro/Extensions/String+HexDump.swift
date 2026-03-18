//
//  String+HexDump.swift
//  TablePro
//
//  Hex dump formatting utilities for binary data display.
//

import Foundation

extension String {
    /// Returns a classic hex dump representation of this string's bytes, or nil if empty.
    ///
    /// Format per line: `OFFSET  HH HH HH HH HH HH HH HH  HH HH HH HH HH HH HH HH  |ASCII...........|`
    /// - Parameter maxBytes: Maximum bytes to display before truncating (default 10KB).
    func formattedAsHexDump(maxBytes: Int = 10_240) -> String? {
        // Convert to bytes: try isoLatin1 first (matches plugin fallback encoding for non-UTF-8 data),
        // then utf8
        guard let bytes = data(using: .isoLatin1) ?? data(using: .utf8) else {
            return nil
        }

        let totalCount = bytes.count
        guard totalCount > 0 else { return nil }

        let displayCount = min(totalCount, maxBytes)
        let bytesArray = [UInt8](bytes.prefix(displayCount))

        var lines: [String] = []
        lines.reserveCapacity(displayCount / 16 + 2)

        let bytesPerLine = 16
        var offset = 0

        while offset < displayCount {
            let lineEnd = min(offset + bytesPerLine, displayCount)
            let lineBytes = bytesArray[offset..<lineEnd]

            // Offset column (8-digit hex)
            var line = String(format: "%08X  ", offset)

            // Hex columns: two groups of 8 bytes
            for i in 0..<bytesPerLine {
                if i == 8 { line += " " }
                if offset + i < lineEnd {
                    line += String(format: "%02X ", lineBytes[offset + i])
                } else {
                    line += "   "
                }
            }

            // ASCII column
            line += " |"
            for byte in lineBytes {
                if byte >= 0x20, byte <= 0x7E {
                    line += String(UnicodeScalar(byte))
                } else {
                    line += "."
                }
            }
            line += "|"

            lines.append(line)
            offset += bytesPerLine
        }

        if totalCount > maxBytes {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            let formattedTotal = formatter.string(from: NSNumber(value: totalCount)) ?? "\(totalCount)"
            lines.append("... (truncated, \(formattedTotal) bytes total)")
        }

        return lines.joined(separator: "\n")
    }

    /// Returns a space-separated hex representation suitable for editing.
    ///
    /// Format: `48 65 6C 6C 6F` — one hex byte pair separated by spaces, no offset or ASCII columns.
    /// - Parameter maxBytes: Maximum bytes to display before truncating (default 10KB).
    func formattedAsEditableHex(maxBytes: Int = 10_240) -> String? {
        guard let bytes = data(using: .isoLatin1) ?? data(using: .utf8) else {
            return nil
        }

        let totalCount = bytes.count
        guard totalCount > 0 else { return nil }

        let displayCount = min(totalCount, maxBytes)
        let bytesArray = [UInt8](bytes.prefix(displayCount))

        var hex = bytesArray.map { String(format: "%02X", $0) }.joined(separator: " ")

        if totalCount > maxBytes {
            hex += " …"
        }

        return hex
    }

    /// Returns a compact single-line hex representation for data grid cells.
    ///
    /// Format: `0x48656C6C6F` for short values, truncated with `…` for longer ones.
    /// - Parameter maxBytes: Maximum bytes to show before truncating (default 64).
    func formattedAsCompactHex(maxBytes: Int = 64) -> String? {
        guard let bytes = data(using: .isoLatin1) ?? data(using: .utf8) else {
            return nil
        }

        let totalCount = bytes.count
        guard totalCount > 0 else { return nil }

        let displayCount = min(totalCount, maxBytes)
        let bytesArray = [UInt8](bytes.prefix(displayCount))

        var hex = "0x"
        for byte in bytesArray {
            hex += String(format: "%02X", byte)
        }

        if totalCount > maxBytes {
            hex += "…"
        }

        return hex
    }
}
