//
//  BeancountDirectiveProjection.swift
//  BeancountDriverPlugin
//

import Foundation

struct BeancountDirectiveProjection: @unchecked Sendable {
    var queries: [[String: Any]] = []
    var custom: [[String: Any]] = []
}

enum BeancountDirectiveProjectionReader {
    private struct Token {
        let value: String
        let quoted: Bool
    }

    static func read(sourceFiles: [URL]) throws -> BeancountDirectiveProjection {
        var projection = BeancountDirectiveProjection()
        for sourceFile in sourceFiles {
            let contents = try String(contentsOf: sourceFile, encoding: .utf8)
            append(contents: contents, sourceURL: sourceFile, to: &projection)
        }
        return projection
    }

    static func read(contents: String, sourceURL: URL) -> BeancountDirectiveProjection {
        var projection = BeancountDirectiveProjection()
        append(contents: contents, sourceURL: sourceURL, to: &projection)
        return projection
    }

    private static func append(
        contents: String,
        sourceURL: URL,
        to projection: inout BeancountDirectiveProjection
    ) {
        var statement: String?
        var statementLine = 0

        for (offset, line) in contents.components(separatedBy: .newlines).enumerated() {
            if statement == nil {
                guard isSupportedDirectiveStart(line) else { continue }
                statement = line
                statementLine = offset + 1
            } else {
                statement? += "\n" + line
            }

            guard let candidate = statement, !hasOpenQuote(candidate) else { continue }
            append(
                statement: candidate,
                sourceURL: sourceURL,
                line: statementLine,
                to: &projection
            )
            statement = nil
        }
    }

    private static func append(
        statement: String,
        sourceURL: URL,
        line: Int,
        to projection: inout BeancountDirectiveProjection
    ) {
        let tokens = tokenize(statement)
        guard tokens.count >= 4, let date = canonicalDate(tokens[0].value) else { return }
        let source: [String: Any] = [
            "filename": sourceURL.path,
            "lineno": line,
            "location": "\(sourceURL.path):\(line)"
        ]

        switch tokens[1].value {
        case "query":
            guard tokens[2].quoted, tokens[3].quoted else { return }
            projection.queries.append(source.merging([
                "date": date,
                "name": tokens[2].value,
                "query": tokens[3].value
            ], uniquingKeysWith: { _, new in new }))
        case "custom":
            guard tokens[2].quoted else { return }
            let customID = projection.custom.count + 1
            projection.custom.append(source.merging([
                "id": customID,
                "date": date,
                "type": tokens[2].value,
                "values": customValues(Array(tokens.dropFirst(3)))
            ], uniquingKeysWith: { _, new in new }))
        default:
            return
        }
    }

    private static func customValues(_ tokens: [Token]) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.quoted {
                rows.append(["value_type": "string", "value": token.value])
            } else if let date = canonicalDate(token.value) {
                rows.append(["value_type": "date", "value": date])
            } else if token.value == "TRUE" || token.value == "FALSE" {
                rows.append(["value_type": "boolean", "value": token.value])
            } else if isNumber(token.value), index + 1 < tokens.count,
                      isCurrency(tokens[index + 1].value) {
                let currency = tokens[index + 1].value
                rows.append([
                    "value_type": "amount",
                    "value": "\(token.value) \(currency)",
                    "number": token.value,
                    "currency": currency
                ])
                index += 1
            } else if token.value.contains(":") {
                rows.append(["value_type": "account", "value": token.value])
            } else if isNumber(token.value) {
                rows.append([
                    "value_type": "number",
                    "value": token.value,
                    "number": token.value
                ])
            }
            index += 1
        }
        return rows
    }

    private static func isSupportedDirectiveStart(_ line: String) -> Bool {
        guard line.first?.isWhitespace == false else { return false }
        let fields = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
        guard fields.count >= 2, canonicalDate(String(fields[0])) != nil else { return false }
        return fields[1] == "query" || fields[1] == "custom"
    }

    private static func canonicalDate(_ value: String) -> String? {
        let parts = value.split(omittingEmptySubsequences: false) { $0 == "-" || $0 == "/" }
        guard parts.count == 3,
              parts[0].count == 4,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return nil
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func isNumber(_ value: String) -> Bool {
        Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) != nil
    }

    private static func isCurrency(_ value: String) -> Bool {
        guard let first = value.first, first.isUppercase else { return false }
        return value.allSatisfy { $0.isUppercase || $0.isNumber || "'._-".contains($0) }
    }

    private static func hasOpenQuote(_ value: String) -> Bool {
        var quoted = false
        var escaped = false
        for character in value {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = quoted
            } else if character == "\"" {
                quoted.toggle()
            } else if character == ";", !quoted {
                break
            }
        }
        return quoted
    }

    private static func tokenize(_ value: String) -> [Token] {
        let characters = Array(value)
        var tokens: [Token] = []
        var index = 0

        while index < characters.count {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count, characters[index] != ";" else { break }

            if characters[index] == "\"" {
                index += 1
                var decoded = ""
                var escaped = false
                while index < characters.count {
                    let character = characters[index]
                    index += 1
                    if escaped {
                        switch character {
                        case "n": decoded.append("\n")
                        case "r": decoded.append("\r")
                        case "t": decoded.append("\t")
                        case "\"", "\\": decoded.append(character)
                        default:
                            decoded.append("\\")
                            decoded.append(character)
                        }
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        break
                    } else {
                        decoded.append(character)
                    }
                }
                tokens.append(Token(value: decoded, quoted: true))
            } else {
                let start = index
                while index < characters.count,
                      !characters[index].isWhitespace,
                      characters[index] != ";" {
                    index += 1
                }
                tokens.append(Token(value: String(characters[start..<index]), quoted: false))
            }
        }
        return tokens
    }
}
