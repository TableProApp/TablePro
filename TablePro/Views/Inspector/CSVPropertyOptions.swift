//
//  CSVPropertyOptions.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum CSVPropertyOptions {
    static let delimiters: [(label: String, byte: UInt8)] = [
        (String(localized: "Comma  ,"), 0x2C),
        (String(localized: "Semicolon  ;"), 0x3B),
        (String(localized: "Tab"), 0x09),
        (String(localized: "Pipe  |"), 0x7C),
        (String(localized: "Colon  :"), 0x3A),
        (String(localized: "Space"), 0x20),
    ]

    static let quotes: [(label: String, byte: UInt8)] = [
        (String(localized: "Double Quote  \""), 0x22),
        (String(localized: "Single Quote  '"), 0x27),
    ]

    static let escapes: [(label: String, byte: UInt8)] = [
        (String(localized: "Doubled Quote"), 0x22),
        (String(localized: "Backslash  \\"), 0x5C),
    ]

    static let backslashEscapeIndex = 1

    static let encodings: [(label: String, encoding: String.Encoding)] = [
        ("UTF-8", .utf8),
        ("UTF-16 LE", .utf16LittleEndian),
        ("UTF-16 BE", .utf16BigEndian),
        ("Latin-1", .isoLatin1),
        ("Windows-1252", .windowsCP1252),
    ]

    static let lineEndings: [(label: String, value: CSVDialect.LineEnding)] = [
        ("LF", .lf),
        ("CRLF", .crlf),
        ("CR", .cr),
    ]

    static func delimiterIndex(for byte: UInt8) -> Int {
        delimiters.firstIndex { $0.byte == byte } ?? 0
    }

    static func quoteIndex(for byte: UInt8) -> Int {
        quotes.firstIndex { $0.byte == byte } ?? 0
    }

    static func escapeIndex(for byte: UInt8) -> Int {
        byte == escapes[backslashEscapeIndex].byte ? backslashEscapeIndex : 0
    }

    static func encodingIndex(for encoding: String.Encoding) -> Int {
        encodings.firstIndex { $0.encoding == encoding } ?? 0
    }

    static func lineEndingIndex(for value: CSVDialect.LineEnding) -> Int {
        lineEndings.firstIndex { $0.value == value } ?? 0
    }

    static func dialect(
        base: CSVDialect,
        delimiterIndex: Int,
        quoteIndex: Int,
        escapeIndex: Int,
        encodingIndex: Int,
        lineEndingIndex: Int
    ) -> CSVDialect {
        var dialect = CSVDialect(
            delimiter: delimiters.indices.contains(delimiterIndex) ? delimiters[delimiterIndex].byte : base.delimiter,
            quoteChar: quotes.indices.contains(quoteIndex) ? quotes[quoteIndex].byte : base.quoteChar,
            encoding: encodings.indices.contains(encodingIndex) ? encodings[encodingIndex].encoding : base.encoding,
            lineEnding: lineEndings.indices.contains(lineEndingIndex) ? lineEndings[lineEndingIndex].value : base.lineEnding,
            hasBom: base.hasBom
        )
        dialect.escapeChar = escapeIndex == backslashEscapeIndex
            ? escapes[backslashEscapeIndex].byte
            : dialect.quoteChar
        return dialect
    }
}
