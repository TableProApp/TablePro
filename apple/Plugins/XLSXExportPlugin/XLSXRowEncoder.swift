//
//  XLSXRowEncoder.swift
//  XLSXExportPlugin
//

import Foundation

// A sheet's XML as bytes appended to one buffer: an export writes every cell through here, and a String per
// cell reference and tag cost more than the values did.
nonisolated enum XLSXRowEncoder {
    static let xmlDeclaration = bytes("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n")
    static let worksheetOpen = bytes(
        "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
    )
    static let worksheetClose = bytes("</sheetData></worksheet>")

    private static let rowOpen = bytes("<row r=\"")
    private static let rowOpenEnd = bytes("\">")
    private static let rowClose = bytes("</row>")
    private static let cellOpen = bytes("<c r=\"")
    private static let stringCellOpenEnd = bytes("\" t=\"inlineStr\"><is><t")
    private static let headerCellOpenEnd = bytes("\" t=\"inlineStr\" s=\"1\"><is><t")
    private static let preserveSpace = bytes(" xml:space=\"preserve\">")
    private static let textOpenEnd = bytes(">")
    private static let stringCellClose = bytes("</t></is></c>")
    private static let numberCellOpenEnd = bytes("\"><v>")
    private static let numberCellClose = bytes("</v></c>")

    private static func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    // "A", "B", ..., "Z", "AA": spreadsheet column letters for a zero-based index.
    static func columnLetters(_ index: Int) -> [UInt8] {
        var letters: [UInt8] = []
        var remaining = index
        repeat {
            letters.append(UInt8(ascii: "A") + UInt8(remaining % 26))
            remaining = remaining / 26 - 1
        } while remaining >= 0
        return letters.reversed()
    }

    // The row number's digits, formatted once for the row and appended to each cell reference.
    static func decimalDigits(of number: Int, into digits: inout [UInt8]) {
        digits.removeAll(keepingCapacity: true)
        var remaining = number
        repeat {
            digits.append(UInt8(ascii: "0") + UInt8(remaining % 10))
            remaining /= 10
        } while remaining > 0
        digits.reverse()
    }

    static func appendRowOpen(rowDigits: [UInt8], to output: inout [UInt8]) {
        output.append(contentsOf: rowOpen)
        output.append(contentsOf: rowDigits)
        output.append(contentsOf: rowOpenEnd)
    }

    static func appendRowClose(to output: inout [UInt8]) {
        output.append(contentsOf: rowClose)
    }

    static func appendStringCell(
        _ value: String,
        column: [UInt8],
        rowDigits: [UInt8],
        isHeader: Bool,
        to output: inout [UInt8]
    ) {
        output.append(contentsOf: cellOpen)
        output.append(contentsOf: column)
        output.append(contentsOf: rowDigits)
        output.append(contentsOf: isHeader ? headerCellOpenEnd : stringCellOpenEnd)
        output.append(contentsOf: XLSXWriter.keepsOuterWhitespace(value) ? preserveSpace : textOpenEnd)
        appendXMLEscaped(value, to: &output)
        output.append(contentsOf: stringCellClose)
    }

    // A number literal is digits, a sign, a point and an exponent, none of which XML escapes.
    static func appendNumberCell(_ literal: String, column: [UInt8], rowDigits: [UInt8], to output: inout [UInt8]) {
        output.append(contentsOf: cellOpen)
        output.append(contentsOf: column)
        output.append(contentsOf: rowDigits)
        output.append(contentsOf: numberCellOpenEnd)
        output.append(contentsOf: literal.utf8)
        output.append(contentsOf: numberCellClose)
    }

    // What each byte becomes: 0 copies it, `stripped` drops it, any other value indexes `replacements`.
    private static let stripped: UInt8 = 0xFF
    private static let replacements: [[UInt8]] = [
        [],
        bytes("&amp;"),
        bytes("&lt;"),
        bytes("&gt;"),
        bytes("&quot;"),
        bytes("&apos;"),
        // A raw CR reads back as LF under XML end-of-line handling.
        bytes("&#13;"),
    ]
    private static let actions: [UInt8] = (0...255).map { value in
        switch UInt8(value) {
        case UInt8(ascii: "&"): 1
        case UInt8(ascii: "<"): 2
        case UInt8(ascii: ">"): 3
        case UInt8(ascii: "\""): 4
        case UInt8(ascii: "'"): 5
        case 0x0D: 6
        // Tab and LF are allowed in XML 1.0; every other control is not, and is dropped.
        case 0x09, 0x0A: 0
        case 0x00...0x1F: stripped
        default: 0
        }
    }

    static func appendXMLEscaped(_ text: String, to output: inout [UInt8]) {
        var text = text
        text.withUTF8 { bytes in
            actions.withUnsafeBufferPointer { actions in
                var runStart = 0
                for index in bytes.indices {
                    let action = actions[Int(bytes[index])]
                    guard action != 0 else { continue }
                    output.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[runStart..<index]))
                    if action != stripped {
                        output.append(contentsOf: replacements[Int(action)])
                    }
                    runStart = index + 1
                }
                output.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[runStart...]))
            }
        }
    }
}

// Text spelled `-?(0|[1-9][0-9]*)(\.[0-9]+)?`, which is most numeric cells. Such text is its own
// `JsonNumberNormalizer.numberLiteral`, has no padding zero, and is finite while the integer part has
// at most 300 digits, so the cell rules need only its digit counts, read off the bytes.
nonisolated struct PlainDecimal: Equatable {
    // Every digit, as `filter(\.isNumber).count` counts them.
    let total: Int
    // From the first nonzero digit to the last, the point skipped.
    let significant: Int

    private static let maximumIntegerDigits = 300

    static func digits(of text: String) -> PlainDecimal? {
        var text = text
        return text.withUTF8 { bytes -> PlainDecimal? in
            var index = 0
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            let integerStart = index
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            let integerDigits = index - integerStart
            guard integerDigits > 0, integerDigits <= maximumIntegerDigits else { return nil }
            guard integerDigits == 1 || bytes[integerStart] != UInt8(ascii: "0") else { return nil }
            var fractionDigits = 0
            if index < bytes.count {
                guard bytes[index] == UInt8(ascii: ".") else { return nil }
                index += 1
                let fractionStart = index
                while index < bytes.count, isDigit(bytes[index]) { index += 1 }
                fractionDigits = index - fractionStart
                guard fractionDigits > 0, index == bytes.count else { return nil }
            }
            var firstNonzero: Int?
            var lastNonzero = 0
            var position = 0
            for byte in bytes[integerStart...] where byte != UInt8(ascii: ".") {
                if byte != UInt8(ascii: "0") {
                    if firstNonzero == nil { firstNonzero = position }
                    lastNonzero = position
                }
                position += 1
            }
            let significant = firstNonzero.map { lastNonzero - $0 + 1 } ?? 0
            return PlainDecimal(total: integerDigits + fractionDigits, significant: significant)
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
}
