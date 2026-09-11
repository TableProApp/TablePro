//
//  TiDBCheckConstraints.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal enum TiDBCheckConstraints {
    static func parse(createTable sql: String) -> [PluginCheckConstraintInfo] {
        guard let body = firstGroup(in: Substring(sql)) else { return [] }
        return topLevelElements(of: body).compactMap(checkConstraint(in:))
    }

    private static func checkConstraint(in element: Substring) -> PluginCheckConstraintInfo? {
        var rest = element
        guard consume("CONSTRAINT", from: &rest),
              let name = consumeBacktickName(from: &rest),
              consume("CHECK", from: &rest)
        else { return nil }
        rest = rest.drop(while: \.isWhitespace)
        guard rest.first == "(", let expression = firstGroup(in: rest) else { return nil }
        return PluginCheckConstraintInfo(name: name, expression: expression.trimmingCharacters(in: .whitespaces))
    }

    private static func consume(_ keyword: String, from rest: inout Substring) -> Bool {
        let trimmed = rest.drop(while: \.isWhitespace)
        guard trimmed.prefix(keyword.count).uppercased() == keyword else { return false }
        let remainder = trimmed.dropFirst(keyword.count)
        guard let next = remainder.first, next.isWhitespace || next == "`" || next == "(" else { return false }
        rest = remainder
        return true
    }

    private static func consumeBacktickName(from rest: inout Substring) -> String? {
        var text = rest.drop(while: \.isWhitespace)
        guard text.first == "`" else { return nil }
        text = text.dropFirst()
        var name = ""
        while let character = text.first {
            text = text.dropFirst()
            if character == "`" {
                guard text.first == "`" else {
                    rest = text
                    return name
                }
                text = text.dropFirst()
            }
            name.append(character)
        }
        return nil
    }

    private static func firstGroup(in text: Substring) -> Substring? {
        var depth = 0
        var start: Substring.Index?
        for (index, mark) in structuralMarks(in: text) {
            switch mark {
            case "(":
                if depth == 0 { start = text.index(after: index) }
                depth += 1
            case ")":
                guard depth > 0 else { return nil }
                depth -= 1
                if depth == 0, let start { return text[start..<index] }
            default:
                continue
            }
        }
        return nil
    }

    private static func topLevelElements(of body: Substring) -> [Substring] {
        var elements: [Substring] = []
        var depth = 0
        var elementStart = body.startIndex
        for (index, mark) in structuralMarks(in: body) {
            switch mark {
            case "(":
                depth += 1
            case ")":
                depth -= 1
            default:
                guard depth == 0 else { continue }
                elements.append(body[elementStart..<index])
                elementStart = body.index(after: index)
            }
        }
        elements.append(body[elementStart...])
        return elements
    }

    private static func structuralMarks(in text: Substring) -> [(index: Substring.Index, mark: Character)] {
        var marks: [(index: Substring.Index, mark: Character)] = []
        var openQuote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let quote = openQuote {
                if character == "\\", quote != "`" {
                    index = text.index(after: index)
                } else if character == quote {
                    openQuote = nil
                }
            } else if character == "'" || character == "\"" || character == "`" {
                openQuote = character
            } else if character == "(" || character == ")" || character == "," {
                marks.append((index, character))
            }
            guard index < text.endIndex else { break }
            index = text.index(after: index)
        }
        return marks
    }
}
