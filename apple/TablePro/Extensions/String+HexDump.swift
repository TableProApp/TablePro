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

    // The first `maxBytes` of `storedBytes` and how many there are in all, without encoding the rest:
    // a cell shows 64 bytes of a value that can run to megabytes.
    private func storedBytesPrefix(_ maxBytes: Int) -> (bytes: Data, count: Int) {
        // A lead byte of 0xC4 or more starts a scalar past U+00FF. Counting in UInt8 runs of 255 lets the
        // loop vectorize: under 1 ms for 6 MB against 13 ms with an Int counter, measured.
        let scan = utf8.withContiguousStorageIfAvailable { buffer -> (fitsLatin1: Bool, scalars: Int) in
            var highest: UInt8 = 0
            var continuations = 0
            var index = 0
            while index < buffer.count {
                let end = Swift.min(index + 255, buffer.count)
                var run: UInt8 = 0
                while index < end {
                    let byte = buffer[index]
                    highest = Swift.max(highest, byte)
                    run &+= byte >> 6 == 2 ? 1 : 0
                    index += 1
                }
                continuations += Int(run)
                if highest >= 0xC4 { return (false, 0) }
            }
            return (true, buffer.count - continuations)
        }
        guard let scan else {
            let bytes = storedBytes
            return (bytes.prefix(maxBytes), bytes.count)
        }
        guard scan.fitsLatin1 else {
            return (Data(utf8.prefix(maxBytes)), utf8.count)
        }
        var bytes = Data(capacity: Swift.min(maxBytes, scan.scalars))
        for scalar in unicodeScalars.prefix(maxBytes) {
            bytes.append(UInt8(truncatingIfNeeded: scalar.value))
        }
        return (bytes, scan.scalars)
    }

    func formattedAsHexDump(maxBytes: Int = 10_240) -> String? {
        let stored = storedBytesPrefix(maxBytes)
        return HexText.dump(stored.bytes, totalCount: stored.count, maxBytes: maxBytes)
    }

    func formattedAsEditableHex(maxBytes: Int = 10_240) -> String? {
        let stored = storedBytesPrefix(maxBytes)
        return HexText.editable(stored.bytes, totalCount: stored.count, maxBytes: maxBytes)
    }

    func formattedAsCompactHex(maxBytes: Int = 64) -> String? {
        let stored = storedBytesPrefix(maxBytes)
        return HexText.compact(stored.bytes, totalCount: stored.count, maxBytes: maxBytes)
    }
}

extension Data {
    func formattedAsHexDump(maxBytes: Int = 10_240) -> String? {
        HexText.dump(prefix(maxBytes), totalCount: count, maxBytes: maxBytes)
    }

    func formattedAsEditableHex(maxBytes: Int = 10_240) -> String? {
        HexText.editable(prefix(maxBytes), totalCount: count, maxBytes: maxBytes)
    }

    func formattedAsCompactHex(maxBytes: Int = 64) -> String? {
        HexText.compact(prefix(maxBytes), totalCount: count, maxBytes: maxBytes)
    }
}

// Each takes the first bytes of a value and the value's whole byte count.
private enum HexText {
    private static let digits = Array("0123456789ABCDEF".utf8)

    private static func append(_ byte: UInt8, to text: inout [UInt8]) {
        text.append(digits[Int(byte >> 4)])
        text.append(digits[Int(byte & 0x0F)])
    }

    static func dump(_ bytes: Data, totalCount: Int, maxBytes: Int) -> String? {
        guard totalCount > 0 else { return nil }

        let displayCount = min(totalCount, maxBytes)
        let bytesArray = [UInt8](bytes.prefix(displayCount))
        let bytesPerLine = HexDumpLayout.bytesPerLine

        var text: [UInt8] = []
        text.reserveCapacity((displayCount / bytesPerLine + 1) * (HexDumpLayout.lineWidthInCharacters + 1))
        var offset = 0
        while offset < displayCount {
            let lineEnd = min(offset + bytesPerLine, displayCount)
            if offset > 0 { text.append(UInt8(ascii: "\n")) }

            for shift in stride(from: 28, through: 0, by: -4) {
                text.append(digits[(offset >> shift) & 0x0F])
            }
            text.append(contentsOf: "  ".utf8)

            for column in 0..<bytesPerLine {
                if column == 8 { text.append(UInt8(ascii: " ")) }
                if offset + column < lineEnd {
                    append(bytesArray[offset + column], to: &text)
                    text.append(UInt8(ascii: " "))
                } else {
                    text.append(contentsOf: "   ".utf8)
                }
            }

            text.append(contentsOf: " |".utf8)
            for byte in bytesArray[offset..<lineEnd] {
                text.append(byte >= 0x20 && byte <= 0x7E ? byte : UInt8(ascii: "."))
            }
            text.append(UInt8(ascii: "|"))
            offset += bytesPerLine
        }

        var lines = text.isEmpty ? [] : [String(bytes: text, encoding: .ascii) ?? ""]
        if totalCount > maxBytes {
            let formattedTotal = totalCount.formatted(.number)
            lines.append("… (truncated, \(formattedTotal) bytes total)")
        }
        return lines.joined(separator: "\n")
    }

    static func editable(_ bytes: Data, totalCount: Int, maxBytes: Int) -> String? {
        guard totalCount > 0 else { return nil }

        let displayCount = min(totalCount, maxBytes)
        var text: [UInt8] = []
        text.reserveCapacity(displayCount * 3 + 4)
        for (index, byte) in bytes.prefix(displayCount).enumerated() {
            if index > 0 { text.append(UInt8(ascii: " ")) }
            append(byte, to: &text)
        }

        var hex = String(bytes: text, encoding: .ascii) ?? ""
        if totalCount > maxBytes {
            hex += " …"
        }
        return hex
    }

    static func compact(_ bytes: Data, totalCount: Int, maxBytes: Int) -> String? {
        guard totalCount > 0 else { return nil }
        let hex = "0x" + bytes.uppercaseHex(maxBytes: maxBytes)
        return totalCount > maxBytes ? hex + "…" : hex
    }
}
