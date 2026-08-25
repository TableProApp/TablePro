//
//  BeancountSourceScanner.swift
//  BeancountDriverPlugin
//

import Foundation

struct BeancountSourceToken: Equatable {
    let value: String
    let quoted: Bool
}

struct BeancountSourceDirective {
    let tokens: [BeancountSourceToken]
    let sourceURL: URL
    let lineNumber: Int
}

/// Splits and tokenizes ledger text for the projections that read the source directly.
///
/// A ledger reaches this through `BeancountSourceGraph.lines`, which the include resolver already
/// split while it followed the includes, so nothing here reopens a file.
enum BeancountSourceScanner {
    /// `CharacterSet.newlines` treats the `\r` and the `\n` of a CRLF pair as two separators, so a
    /// CRLF ledger comes back with a phantom empty component between every pair. That shifts every
    /// line number and reads as a blank line to anything tracking directive context, so the pairs
    /// are collapsed before the split.
    static func lines(of contents: String) -> [String] {
        contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
    }

    /// Calls `body` once per dated top-level directive, in source order.
    ///
    /// A Beancount string may span lines, so a directive is accumulated until its quotes balance
    /// rather than being read one physical line at a time. `lineNumber` is the directive's first
    /// line. A directive left open at the end of the file is dropped.
    static func scanDirectives(
        lines: [String],
        sourceURL: URL,
        _ body: (BeancountSourceDirective) -> Void
    ) {
        var statement: String?
        var statementLine = 0

        for (offset, line) in lines.enumerated() {
            if statement == nil {
                guard startsDirective(line) else { continue }
                statement = line
                statementLine = offset + 1
            } else {
                statement? += "\n" + line
            }

            guard let candidate = statement, !hasOpenQuote(candidate) else { continue }
            body(
                BeancountSourceDirective(
                    tokens: tokenize(candidate),
                    sourceURL: sourceURL,
                    lineNumber: statementLine
                )
            )
            statement = nil
        }
    }

    static func canonicalDate(_ value: String) -> String? {
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

    static func tokenize(_ value: String) -> [BeancountSourceToken] {
        let characters = Array(value)
        var tokens: [BeancountSourceToken] = []
        var index = 0

        while index < characters.count {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count, characters[index] != ";" else { break }

            if characters[index] == "\"" {
                index += 1
                tokens.append(BeancountSourceToken(value: quotedValue(characters, from: &index), quoted: true))
            } else {
                let start = index
                while index < characters.count,
                      !characters[index].isWhitespace,
                      characters[index] != ";" {
                    index += 1
                }
                tokens.append(BeancountSourceToken(value: String(characters[start..<index]), quoted: false))
            }
        }
        return tokens
    }

    private static func quotedValue(_ characters: [Character], from index: inout Int) -> String {
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
        return decoded
    }

    private static func startsDirective(_ line: String) -> Bool {
        guard line.first?.isWhitespace == false,
              let field = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).first else {
            return false
        }
        return canonicalDate(String(field)) != nil
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
}
