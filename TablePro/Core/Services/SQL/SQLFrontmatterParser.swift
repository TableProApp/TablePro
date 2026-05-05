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

    static func parse(_ content: String) -> Metadata {
        var metadata = Metadata()
        let nsContent = content as NSString
        let length = nsContent.length
        var lineStart = 0

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

            guard let entry = parseLine(line) else { break }
            switch entry.key {
            case "name": metadata.name = entry.value
            case "keyword": metadata.keyword = entry.value.isEmpty ? nil : entry.value
            case "description": metadata.description = entry.value
            default: break
            }

            lineStart = lineEnd + 1
            if lineStart < length, nsContent.character(at: lineEnd) == 0x0D,
               lineStart < length, nsContent.character(at: lineStart) == 0x0A {
                lineStart += 1
            }
        }

        return metadata
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
