//
//  MySQLCreateTableScanner.swift
//  MySQLDriverPlugin
//

import Foundation

internal enum MySQLCreateTableScanner {
    static func firstGroup(in text: Substring) -> Substring? {
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

    static func topLevelElements(of body: Substring) -> [Substring] {
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

    static func consume(_ keyword: String, from rest: inout Substring) -> Bool {
        let trimmed = rest.drop(while: \.isWhitespace)
        guard trimmed.prefix(keyword.count).uppercased() == keyword else { return false }
        let remainder = trimmed.dropFirst(keyword.count)
        guard let next = remainder.first, next.isWhitespace || next == "`" || next == "(" else { return false }
        rest = remainder
        return true
    }

    static func consumeBacktickName(from rest: inout Substring) -> String? {
        consumeQuotedName(from: &rest, quote: "`")
    }

    static func consumeQuotedName(from rest: inout Substring, quote: Character) -> String? {
        var text = rest.drop(while: \.isWhitespace)
        guard text.first == quote else { return nil }
        text = text.dropFirst()
        var name = ""
        while let character = text.first {
            text = text.dropFirst()
            if character == quote {
                guard text.first == quote else {
                    rest = text
                    return name
                }
                text = text.dropFirst()
            }
            name.append(character)
        }
        return nil
    }

    static func topLevelTokens(of text: Substring) -> [Substring] {
        var tokens: [Substring] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else {
                index = text.index(after: index)
                continue
            }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = endOfUnit(in: text, from: index)
            }
            tokens.append(text[start..<index])
        }
        return tokens
    }

    static func endOfQuoted(in text: Substring, from start: Substring.Index) -> Substring.Index {
        let quote = text[start]
        var index = text.index(after: start)
        while index < text.endIndex {
            let character = text[index]
            if character == "\\", quote != "`" {
                index = text.index(after: index)
                guard index < text.endIndex else { return text.endIndex }
                index = text.index(after: index)
                continue
            }
            index = text.index(after: index)
            guard character == quote else { continue }
            guard index < text.endIndex, text[index] == quote else { return index }
            index = text.index(after: index)
        }
        return text.endIndex
    }

    private static func endOfUnit(in text: Substring, from index: Substring.Index) -> Substring.Index {
        switch text[index] {
        case "'", "\"", "`":
            return endOfQuoted(in: text, from: index)
        case "(":
            return endOfGroup(in: text, from: index)
        default:
            return text.index(after: index)
        }
    }

    private static func endOfGroup(in text: Substring, from start: Substring.Index) -> Substring.Index {
        var depth = 0
        var index = start
        while index < text.endIndex {
            switch text[index] {
            case "'", "\"", "`":
                index = endOfQuoted(in: text, from: index)
                continue
            case "(":
                depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return text.index(after: index) }
            default:
                break
            }
            index = text.index(after: index)
        }
        return text.endIndex
    }

    private static func structuralMarks(in text: Substring) -> [(index: Substring.Index, mark: Character)] {
        var marks: [(index: Substring.Index, mark: Character)] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            switch character {
            case "'", "\"", "`":
                index = endOfQuoted(in: text, from: index)
                continue
            case "(", ")", ",":
                marks.append((index, character))
            default:
                break
            }
            index = text.index(after: index)
        }
        return marks
    }
}
