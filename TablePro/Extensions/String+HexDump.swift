//
//  String+HexDump.swift
//  TablePro
//
//  Hex dump formatting utilities for binary data display.
//

import Foundation

/// The dump's own column arithmetic, so a view that has to size itself around a line does not
/// restate it. A line is a fixed width in characters, which only means a fixed width in points
/// while the font stays monospaced.
internal enum HexDumpLayout {
    static let bytesPerLine = 16

    private static let offsetColumnWidth = 10
    private static let hexByteWidth = 3
    private static let midGroupGapWidth = 1
    private static let asciiFrameWidth = 3

    static let lineWidthInCharacters =
        offsetColumnWidth
            + bytesPerLine * hexByteWidth
            + midGroupGapWidth
            + asciiFrameWidth
            + bytesPerLine
}

extension String {
    /// The bytes this string stands for.
    ///
    /// A driver that hands binary content over as a string writes one character per stored byte, so
    /// ISO Latin-1 is what recovers them; a string holding a scalar above U+00FF cannot have come
    /// from that path and is its own UTF-8. Every reader of a stored value has to agree on this, or
    /// the hex dump, the byte count and the image sniffer answer differently for one cell.
    var storedBytes: Data {
        data(using: .isoLatin1) ?? Data(utf8)
    }

    /// Returns a classic hex dump representation of this string's bytes, or nil if empty.
    ///
    /// Format per line: `OFFSET  HH HH HH HH HH HH HH HH  HH HH HH HH HH HH HH HH  |ASCII...........|`
    /// - Parameter maxBytes: Maximum bytes to display before truncating (default 10KB).
    func formattedAsHexDump(maxBytes: Int = 10_240) -> String? {
        let bytes = storedBytes

        let totalCount = bytes.count
        guard totalCount > 0 else { return nil }

        let displayCount = min(totalCount, maxBytes)
        let bytesArray = [UInt8](bytes.prefix(displayCount))

        var lines: [String] = []
        let bytesPerLine = HexDumpLayout.bytesPerLine
        lines.reserveCapacity(displayCount / bytesPerLine + 2)

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
            let formattedTotal = totalCount.formatted(.number)
            lines.append("… (truncated, \(formattedTotal) bytes total)")
        }

        return lines.joined(separator: "\n")
    }

    /// Returns a space-separated hex representation suitable for editing.
    ///
    /// Format: `48 65 6C 6C 6F` — one hex byte pair separated by spaces, no offset or ASCII columns.
    /// - Parameter maxBytes: Maximum bytes to display before truncating (default 10KB).
    func formattedAsEditableHex(maxBytes: Int = 10_240) -> String? {
        let bytes = storedBytes

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
        let bytes = storedBytes

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
