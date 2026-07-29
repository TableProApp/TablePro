//
//  DotenvParser.swift
//  TablePro
//

import Foundation

struct DotenvEntry: Sendable {
    let key: String
    let value: String
    let isSingleQuoted: Bool
    let hasUnresolvedReference: Bool
}

struct DotenvDocument: Sendable {
    private(set) var entries: [DotenvEntry] = []
    private var positions: [String: Int] = [:]

    mutating func upsert(_ entry: DotenvEntry) {
        if let existing = positions[entry.key] {
            entries[existing] = entry
            return
        }
        positions[entry.key] = entries.count
        entries.append(entry)
    }

    func entry(for key: String) -> DotenvEntry? {
        guard let position = positions[key] else {
            return nil
        }
        return entries[position]
    }

    subscript(key: String) -> String? {
        guard let entry = entry(for: key), !entry.hasUnresolvedReference else {
            return nil
        }
        let trimmed = entry.value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum DotenvValueQuoting: Sendable {
    case none
    case single
    case double
}

struct DotenvAssignment: Sendable {
    let key: String
    let rawValue: String
    let quoting: DotenvValueQuoting
}

enum DotenvParser {
    static let keyAllowedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-"
    )

    static func parse(
        _ contents: String,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DotenvDocument {
        var document = DotenvDocument()
        let characters = Array(normalize(contents))
        var index = 0
        while index < characters.count {
            skipBlankLinesAndComments(characters, &index)
            guard index < characters.count else {
                break
            }
            guard let assignment = readAssignment(characters, &index) else {
                continue
            }
            document.upsert(resolve(assignment, document: document, processEnvironment: processEnvironment))
        }
        return document
    }

    static func normalize(_ contents: String) -> String {
        var text = contents
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    static func skipBlankLinesAndComments(_ characters: [Character], _ index: inout Int) {
        while index < characters.count {
            let character = characters[index]
            if character == "\n" || character == " " || character == "\t" {
                index += 1
                continue
            }
            if character == "#" {
                skipToLineEnd(characters, &index)
                continue
            }
            return
        }
    }

    static func skipToLineEnd(_ characters: [Character], _ index: inout Int) {
        while index < characters.count, characters[index] != "\n" {
            index += 1
        }
    }

    static func readAssignment(_ characters: [Character], _ index: inout Int) -> DotenvAssignment? {
        var rawKey = ""
        while index < characters.count, characters[index] != "=", characters[index] != "\n" {
            rawKey.append(characters[index])
            index += 1
        }
        guard index < characters.count, characters[index] == "=" else {
            skipToLineEnd(characters, &index)
            return nil
        }
        index += 1
        guard let key = normalizeKey(rawKey) else {
            skipToLineEnd(characters, &index)
            return nil
        }
        while index < characters.count, characters[index] == " " || characters[index] == "\t" {
            index += 1
        }
        let value = readValue(characters, &index)
        return DotenvAssignment(key: key, rawValue: value.raw, quoting: value.quoting)
    }

    static func normalizeKey(_ rawKey: String) -> String? {
        var key = rawKey.trimmingCharacters(in: .whitespaces)
        if key.hasPrefix("export") {
            let afterExport = key.dropFirst("export".count)
            if let first = afterExport.first, first == " " || first == "\t" {
                key = String(afterExport).trimmingCharacters(in: .whitespaces)
            }
        }
        guard !key.isEmpty else {
            return nil
        }
        guard key.unicodeScalars.allSatisfy({ keyAllowedCharacters.contains($0) }) else {
            return nil
        }
        return key
    }

    static func readValue(
        _ characters: [Character],
        _ index: inout Int
    ) -> (raw: String, quoting: DotenvValueQuoting) {
        guard index < characters.count else {
            return ("", .none)
        }
        switch characters[index] {
        case "\"":
            return (readQuoted(characters, &index, delimiter: "\"", decodingEscapes: true), .double)
        case "'":
            return (readQuoted(characters, &index, delimiter: "'", decodingEscapes: false), .single)
        default:
            return (readUnquoted(characters, &index), .none)
        }
    }
}
