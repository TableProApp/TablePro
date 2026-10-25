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
        let nsString = self as NSString
        let length = nsString.length
        guard length > 0 else { return false }
        for index in 0..<length {
            let character = nsString.character(at: index)
            if character == 0x0A || character == 0x0D || character == 0x0B || character == 0x0C
                || character == 0x85 || character == 0x2028 || character == 0x2029 {
                return true
            }
        }
        return false
    }

    var sanitizedForCellDisplay: String {
        flattenedOntoOneLine(keepingLoneCarriageReturns: false)
    }

    // A CR with no LF after it is usually what is left of a CRLF split on LF, so a cell keeps it for the renderer to mark.
    var flattenedForCell: String {
        flattenedOntoOneLine(keepingLoneCarriageReturns: true)
    }

    // What a cell shows while marks are off: the lone CR reads as the space it always did.
    var shownWithoutMarks: String {
        guard utf16.contains(0x0D) else { return self }
        return replacingOccurrences(of: "\r", with: " ", options: .literal)
    }

    private func flattenedOntoOneLine(keepingLoneCarriageReturns: Bool) -> String {
        let nsString = self as NSString
        let length = nsString.length
        guard length > 0 else { return self }

        var mutable: NSMutableString?
        var copiedUpTo = 0
        for index in 0..<length {
            let character = nsString.character(at: index)
            guard character == 0x0A || character == 0x0D || character == 0x0B || character == 0x0C
                || character == 0x85 || character == 0x2028 || character == 0x2029 else { continue }
            if character == 0x0D, keepingLoneCarriageReturns,
               index + 1 >= length || nsString.character(at: index + 1) != 0x0A {
                continue
            }

            if mutable == nil {
                mutable = NSMutableString(capacity: length)
            }
            if index > copiedUpTo {
                mutable?.append(nsString.substring(with: NSRange(location: copiedUpTo, length: index - copiedUpTo)))
            }
            mutable?.append(" ")
            copiedUpTo = index + 1
        }

        guard let result = mutable else { return self }
        if copiedUpTo < length {
            result.append(nsString.substring(with: NSRange(location: copiedUpTo, length: length - copiedUpTo)))
        }
        return result as String
    }
}
