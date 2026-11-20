//
//  DataGridCellText.swift
//  TablePro
//

import AppKit

extension NSFont {
    func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

internal extension String {
    var containsLineBreak: Bool {
        var text = self
        return text.withUTF8 { bytes in
            for index in bytes.indices where Self.lineBreakLength(in: bytes, at: index) > 0 {
                return true
            }
            return false
        }
    }

    var sanitizedForCellDisplay: String {
        flattenedOntoOneLine(keepingLoneCarriageReturns: false)
    }

    // A CR with no LF after it is usually what is left of a CRLF split on LF, so a cell keeps it for the renderer to mark.
    var flattenedForCell: String {
        flattenedOntoOneLine(keepingLoneCarriageReturns: true)
    }

    // What a wrapping cell lays out: every break form is one LF, CRLF counts once, and a break that ends the value goes.
    var keepingLineBreaksForCell: String {
        var text = self
        let normalized: String? = text.withUTF8 { bytes in
            var output: [UInt8] = []
            var copiedUpTo = 0
            var index = 0
            var changed = false
            while index < bytes.count {
                var length = Self.lineBreakLength(in: bytes, at: index)
                guard length > 0 else {
                    index += 1
                    continue
                }
                if bytes[index] == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    length = 2
                }
                let endsText = index + length == bytes.count
                if length == 1, bytes[index] == 0x0A, !endsText {
                    index += 1
                    continue
                }
                if !changed {
                    output.reserveCapacity(bytes.count)
                    changed = true
                }
                output.append(contentsOf: bytes[copiedUpTo..<index])
                if !endsText {
                    output.append(0x0A)
                }
                index += length
                copiedUpTo = index
            }
            guard changed else { return nil }
            output.append(contentsOf: bytes[copiedUpTo...])
            return String(bytes: output, encoding: .utf8)
        }
        return normalized ?? self
    }

    // What a cell shows while marks are off: the lone CR reads as the space it always did.
    var shownWithoutMarks: String {
        guard utf8.contains(0x0D) else { return self }
        return replacingOccurrences(of: "\r", with: " ", options: .literal)
    }

    // The first `limit` UTF-16 units, cut before a surrogate pair rather than through it; nil when the text fits.
    func clipped(toUTF16Units limit: Int) -> String? {
        guard utf8.count > limit else { return nil }
        var text = self
        return text.withUTF8 { bytes in
            var units = 0
            for index in bytes.indices where bytes[index] & 0xC0 != 0x80 {
                units += bytes[index] >= 0xF0 ? 2 : 1
                if units > limit {
                    return String(bytes: bytes[..<index], encoding: .utf8)
                }
            }
            return nil
        }
    }

    // LF, VT, FF and CR are one byte, NEL two, the line and paragraph separators three.
    private static func lineBreakLength(in bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Int {
        switch bytes[index] {
        case 0x0A, 0x0B, 0x0C, 0x0D:
            return 1
        case 0xC2:
            return index + 1 < bytes.count && bytes[index + 1] == 0x85 ? 2 : 0
        case 0xE2:
            guard index + 2 < bytes.count, bytes[index + 1] == 0x80 else { return 0 }
            return bytes[index + 2] == 0xA8 || bytes[index + 2] == 0xA9 ? 3 : 0
        default:
            return 0
        }
    }

    private func flattenedOntoOneLine(keepingLoneCarriageReturns: Bool) -> String {
        var text = self
        let flattened: String? = text.withUTF8 { bytes in
            var output: [UInt8] = []
            var copiedUpTo = 0
            var index = 0
            while index < bytes.count {
                let length = Self.lineBreakLength(in: bytes, at: index)
                guard length > 0 else {
                    index += 1
                    continue
                }
                if bytes[index] == 0x0D, keepingLoneCarriageReturns,
                   index + 1 >= bytes.count || bytes[index + 1] != 0x0A {
                    index += 1
                    continue
                }
                if output.isEmpty {
                    output.reserveCapacity(bytes.count)
                }
                output.append(contentsOf: bytes[copiedUpTo..<index])
                output.append(0x20)
                index += length
                copiedUpTo = index
            }
            guard copiedUpTo > 0 else { return nil }
            output.append(contentsOf: bytes[copiedUpTo...])
            return String(bytes: output, encoding: .utf8)
        }
        return flattened ?? self
    }
}
