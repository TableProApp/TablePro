//
//  SQLFrontmatterParser.swift
//  TablePro
//

import Foundation

internal enum SQLFrontmatter {
    enum Key: String, CaseIterable, Comparable {
        case name
        case keyword
        case description

        static func < (lhs: Key, rhs: Key) -> Bool {
            lhs.canonicalPosition < rhs.canonicalPosition
        }

        private var canonicalPosition: Int {
            switch self {
            case .name: 0
            case .keyword: 1
            case .description: 2
            }
        }
    }

    struct Metadata: Equatable {
        var name: String?
        var keyword: String?
        var description: String?

        func value(for key: Key) -> String? {
            switch key {
            case .name: name
            case .keyword: keyword
            case .description: description
            }
        }
    }

    struct HeaderLine: Equatable {
        let text: String
        let terminator: String
        let key: String
        let value: String

        var ownedKey: Key? {
            Key(rawValue: key)
        }
    }

    struct Document: Equatable {
        let byteOrderMark: String
        let header: [HeaderLine]
        let body: String
    }

    private static let byteOrderMark: Character = "\u{FEFF}"
    private static let lineFeed: unichar = 0x0A
    private static let carriageReturn: unichar = 0x0D

    static func parse(_ content: String) -> Metadata {
        split(content).header.reduce(into: Metadata()) { metadata, line in
            switch line.ownedKey {
            case .name: metadata.name = line.value
            case .keyword: metadata.keyword = line.value.isEmpty ? nil : line.value
            case .description: metadata.description = line.value
            case nil: break
            }
        }
    }

    static func split(_ content: String) -> Document {
        let hasByteOrderMark = content.first == byteOrderMark
        let nsContent = (hasByteOrderMark ? String(content.dropFirst()) : content) as NSString
        let length = nsContent.length
        var header: [HeaderLine] = []
        var lineStart = 0

        while lineStart < length {
            let lineEnd = endOfLine(in: nsContent, from: lineStart)
            let text = nsContent.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            guard let entry = parseLine(text.trimmingCharacters(in: .whitespaces)) else { break }

            let nextLineStart = startOfNextLine(in: nsContent, after: lineEnd)
            header.append(HeaderLine(
                text: text,
                terminator: nsContent.substring(with: NSRange(location: lineEnd, length: nextLineStart - lineEnd)),
                key: entry.key,
                value: entry.value
            ))
            lineStart = nextLineStart
        }

        return Document(
            byteOrderMark: hasByteOrderMark ? String(byteOrderMark) : "",
            header: header,
            body: nsContent.substring(from: lineStart)
        )
    }

    private static func endOfLine(in content: NSString, from lineStart: Int) -> Int {
        var lineEnd = lineStart
        while lineEnd < content.length {
            let char = content.character(at: lineEnd)
            if char == lineFeed || char == carriageReturn { break }
            lineEnd += 1
        }
        return lineEnd
    }

    private static func startOfNextLine(in content: NSString, after lineEnd: Int) -> Int {
        guard lineEnd < content.length else { return lineEnd }
        guard content.character(at: lineEnd) == carriageReturn else { return lineEnd + 1 }
        let afterCarriageReturn = lineEnd + 1
        guard afterCarriageReturn < content.length,
              content.character(at: afterCarriageReturn) == lineFeed else {
            return afterCarriageReturn
        }
        return afterCarriageReturn + 1
    }

    private static func parseLine(_ line: String) -> (key: String, value: String)? {
        guard line.hasPrefix("--") else { return nil }
        var rest = line.dropFirst(2).drop { $0 == " " || $0 == "\t" }
        guard rest.first == "@" else { return nil }
        rest = rest.dropFirst()
        guard let colonIndex = rest.firstIndex(of: ":") else { return nil }
        let key = rest[rest.startIndex..<colonIndex]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        let value = rest[rest.index(after: colonIndex)...]
            .trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }
}
