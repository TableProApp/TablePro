//
//  BeancountDirectiveDetails.swift
//  BeancountDriverPlugin
//

import Foundation

struct BeancountDirectiveDetails: @unchecked Sendable {
    var notes: [[String: Any]] = []
    var balances: [[String: Any]] = []
    var metadata: [[String: Any]] = []
}

enum BeancountDirectiveDetailsReader {
    private struct Context {
        let type: String
        let date: String
        let sourceURL: URL
    }

    private struct Token {
        let value: String
        let quoted: Bool
    }

    static func read(sourceFiles: [URL]) throws -> BeancountDirectiveDetails {
        var details = BeancountDirectiveDetails()
        for sourceFile in sourceFiles {
            let contents = try String(contentsOf: sourceFile, encoding: .utf8)
            append(contents: contents, sourceURL: sourceFile, to: &details)
        }
        return details
    }

    static func read(contents: String, sourceURL: URL) -> BeancountDirectiveDetails {
        var details = BeancountDirectiveDetails()
        append(contents: contents, sourceURL: sourceURL, to: &details)
        return details
    }

    private static func append(
        contents: String,
        sourceURL: URL,
        to details: inout BeancountDirectiveDetails
    ) {
        var context: Context?
        for (offset, line) in contents.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            if line.first?.isWhitespace == false {
                context = topLevelContext(line, sourceURL: sourceURL)
                appendTopLevel(line, sourceURL: sourceURL, line: lineNumber, to: &details)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                context = nil
            } else if let context,
                      context.type != "transaction",
                      let metadata = metadataRow(
                          line,
                          context: context,
                          lineNumber: lineNumber
                      ) {
                details.metadata.append(metadata)
            }
        }
    }

    private static func topLevelContext(_ line: String, sourceURL: URL) -> Context? {
        let tokens = tokenize(line)
        guard tokens.count >= 2, let date = canonicalDate(tokens[0].value) else { return nil }
        let type = tokens[1].value == "txn" || isTransactionFlag(tokens[1].value)
            ? "transaction"
            : tokens[1].value
        return Context(type: type, date: date, sourceURL: sourceURL)
    }

    private static func appendTopLevel(
        _ lineText: String,
        sourceURL: URL,
        line: Int,
        to details: inout BeancountDirectiveDetails
    ) {
        let tokens = tokenize(lineText)
        guard tokens.count >= 2, let date = canonicalDate(tokens[0].value) else { return }

        switch tokens[1].value {
        case "note":
            guard tokens.count >= 4 else { return }
            details.notes.append([
                "date": date,
                "account": tokens[2].value,
                "comment": tokens[3].value,
                "tags": tokens.dropFirst(4).compactMap { $0.value.first == "#" ? String($0.value.dropFirst()) : nil },
                "links": tokens.dropFirst(4).compactMap { $0.value.first == "^" ? String($0.value.dropFirst()) : nil },
                "filename": sourceURL.path,
                "lineno": line
            ])
        case "balance":
            guard tokens.count >= 5, let currency = tokens.last?.value else { return }
            let toleranceIndex = tokens.firstIndex { $0.value == "~" }
            var row: [String: Any] = [
                "date": date,
                "account": tokens[2].value,
                "currency": currency,
                "filename": sourceURL.path,
                "lineno": line
            ]
            if let toleranceIndex, toleranceIndex + 1 < tokens.count {
                row["tolerance"] = tokens[toleranceIndex + 1].value
            }
            details.balances.append(row)
        default:
            return
        }
    }

    private static func metadataRow(
        _ line: String,
        context: Context,
        lineNumber: Int
    ) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let key = String(trimmed[..<colon])
        guard !key.isEmpty,
              key.first?.isLowercase == true,
              key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        let rawValue = String(trimmed[trimmed.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        let valueTokens = tokenize(rawValue)
        guard !valueTokens.isEmpty else { return nil }
        let value = valueTokens.count == 1 && valueTokens[0].quoted
            ? valueTokens[0].value
            : valueTokens.map(\.value).joined(separator: " ")
        return [
            "directive_type": context.type,
            "date": context.date,
            "key": key,
            "value": value,
            "filename": context.sourceURL.path,
            "lineno": lineNumber
        ]
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

    private static func isTransactionFlag(_ value: String) -> Bool {
        value.count == 1 && (value == "*" || value == "!" || value.first?.isLetter == true)
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
