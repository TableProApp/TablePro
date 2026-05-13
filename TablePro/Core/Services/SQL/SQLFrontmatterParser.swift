//
//  SQLFrontmatterParser.swift
//  TablePro
//

import Foundation

internal enum SQLFrontmatter {
    struct Metadata: Equatable {
        var name: String?
        var keyword: String?
        var description: String?
    }

    struct Parsed: Equatable {
        var metadata: Metadata
        var bodyCharOffset: Int
    }

    static func parse(_ content: String) -> Metadata {
        parseWithBody(content).metadata
    }

    static func parseWithBody(_ content: String) -> Parsed {
        var metadata = Metadata()
        let bomLength = content.first == "\u{FEFF}" ? 1 : 0
        let stripped = bomLength > 0 ? String(content.dropFirst()) : content
        let nsContent = stripped as NSString
        let length = nsContent.length
        var lineStart = 0
        var bodyOffset = 0

        while lineStart < length {
            var lineEnd = lineStart
            while lineEnd < length {
                let char = nsContent.character(at: lineEnd)
                if char == 0x0A || char == 0x0D { break }
                lineEnd += 1
            }

            let line = nsContent
                .substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
                .trimmingCharacters(in: .whitespaces)

            guard let entry = parseLine(line) else {
                bodyOffset = lineStart
                return Parsed(metadata: metadata, bodyCharOffset: bodyOffset + bomLength)
            }
            switch entry.key {
            case "name": metadata.name = entry.value
            case "keyword": metadata.keyword = entry.value.isEmpty ? nil : entry.value
            case "description": metadata.description = entry.value
            default: break
            }

            var nextLineStart = lineEnd
            if nextLineStart < length, nsContent.character(at: nextLineStart) == 0x0D {
                nextLineStart += 1
                if nextLineStart < length, nsContent.character(at: nextLineStart) == 0x0A {
                    nextLineStart += 1
                }
            } else if nextLineStart < length, nsContent.character(at: nextLineStart) == 0x0A {
                nextLineStart += 1
            }
            lineStart = nextLineStart
            bodyOffset = lineStart
        }

        return Parsed(metadata: metadata, bodyCharOffset: bodyOffset + bomLength)
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
