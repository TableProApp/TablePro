//
//  StarRocksLiteral.swift
//  MySQLDriverPlugin
//

import Foundation
import TableProPluginKit

internal enum StarRocksLiteral {
    // AstBuilder.escapeBackSlash reads `\f` as `f`, so a form feed stays a raw character, which the literal takes.
    static func escapeString(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count + 2)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "'": result += "''"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\0": result += "\\0"
            case "\u{08}": result += "\\b"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    static func quoted(_ value: String) -> String {
        "'\(escapeString(value))'"
    }

    static func hex(_ data: Data) -> String {
        "X'" + data.map { String(format: "%02X", $0) }.joined() + "'"
    }

    static func literal(for value: PluginCellValue) -> String {
        switch value {
        case .null:
            return "NULL"
        case .text(let text):
            return quoted(text)
        case .bytes(let data):
            return hex(data)
        }
    }

    static func inline(_ sql: String, parameters: [PluginCellValue]) throws -> String {
        let scalars = Array(sql.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        var nextParameter = 0

        func peek(_ offset: Int) -> Unicode.Scalar? {
            let position = index + offset
            return position < scalars.count ? scalars[position] : nil
        }

        // StarRocksLex.g4 ends `--` at a carriage return as well as a line feed.
        func copyThroughLineEnd() {
            while index < scalars.count, scalars[index] != "\n", scalars[index] != "\r" {
                output.append(scalars[index])
                index += 1
            }
        }

        func copyBlockComment() {
            output.append(scalars[index])
            output.append(scalars[index + 1])
            index += 2
            while index < scalars.count {
                if scalars[index] == "*", peek(1) == "/" {
                    output.append("*")
                    output.append("/")
                    index += 2
                    return
                }
                output.append(scalars[index])
                index += 1
            }
        }

        func copyQuoted(by terminator: Unicode.Scalar, honoursBackslash: Bool) {
            output.append(scalars[index])
            index += 1
            while index < scalars.count {
                let scalar = scalars[index]
                output.append(scalar)
                if honoursBackslash, scalar == "\\", let next = peek(1) {
                    output.append(next)
                    index += 2
                    continue
                }
                index += 1
                guard scalar == terminator else { continue }
                if peek(0) == terminator {
                    output.append(terminator)
                    index += 1
                    continue
                }
                return
            }
        }

        // `$` is a letter to StarRocksLex.g4, so a name or a number runs on through `$$`. A `$$` opens an attachment only
        // where that token is the longer one, and a tie goes to the name, the rule the grammar lists first. One left
        // open could be closed by a `$$` in a bound value, so nothing after it is bound.
        func copyWordOrAttachment() -> Bool {
            var end = Self.wordEnd(in: scalars, at: index) ?? index
            if scalars[index] == "$", peek(1) == "$" {
                end = max(end, Self.attachmentEnd(in: scalars, at: index) ?? scalars.count)
            }
            guard end > index else { return false }
            output.append(contentsOf: scalars[index..<end])
            index = end
            return true
        }

        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case "-" where peek(1) == "-":
                copyThroughLineEnd()
            case "/" where peek(1) == "*":
                copyBlockComment()
            case "'":
                copyQuoted(by: "'", honoursBackslash: true)
            case "\"":
                copyQuoted(by: "\"", honoursBackslash: true)
            case "`":
                copyQuoted(by: "`", honoursBackslash: false)
            case "?":
                if nextParameter < parameters.count {
                    output.append(contentsOf: literal(for: parameters[nextParameter]).unicodeScalars)
                }
                nextParameter += 1
                index += 1
            default:
                guard !copyWordOrAttachment() else { continue }
                output.append(scalar)
                index += 1
            }
        }

        guard nextParameter == parameters.count else {
            throw DatabendLiteralError.parameterCountMismatch(placeholders: nextParameter, values: parameters.count)
        }
        return String(output)
    }

    // The longest of LETTER_IDENTIFIER, DIGIT_IDENTIFIER, DOT_IDENTIFIER and the number rules at `index`, or nil when
    // none starts there.
    static func wordEnd(in scalars: [Unicode.Scalar], at index: Int) -> Int? {
        func letters(from start: Int) -> Int {
            var cursor = start
            while cursor < scalars.count, isLetter(scalars[cursor]) || isDigit(scalars[cursor]) {
                cursor += 1
            }
            return cursor
        }
        let first = scalars[index]
        if isLetter(first) { return letters(from: index + 1) }
        if isDigit(first) { return max(letters(from: index + 1), numberEnd(in: scalars, at: index)) }
        guard first == ".", index + 1 < scalars.count, isDigit(scalars[index + 1]) else { return nil }
        let dotIdentifier = letters(from: index + 2)
        return max(dotIdentifier > index + 2 ? dotIdentifier : index, numberEnd(in: scalars, at: index))
    }

    // `DIGIT+ ('.' DIGIT*)?` or `'.' DIGIT+`, then an optional EXPONENT, whose `E` CaseInsensitiveStream reads in
    // either case.
    private static func numberEnd(in scalars: [Unicode.Scalar], at index: Int) -> Int {
        func digits(from start: Int) -> Int {
            var cursor = start
            while cursor < scalars.count, isDigit(scalars[cursor]) {
                cursor += 1
            }
            return cursor
        }
        var end = digits(from: index)
        if end < scalars.count, scalars[end] == "." {
            let fraction = digits(from: end + 1)
            if end > index || fraction > end + 1 { end = fraction }
        }
        guard end > index, end < scalars.count, scalars[end] == "e" || scalars[end] == "E" else { return end }
        var exponent = end + 1
        if exponent < scalars.count, scalars[exponent] == "+" || scalars[exponent] == "-" { exponent += 1 }
        let exponentEnd = digits(from: exponent)
        return exponentEnd > exponent ? exponentEnd : end
    }

    // ATTACHMENT, `$$ .*? $$`, or nil when it does not close.
    private static func attachmentEnd(in scalars: [Unicode.Scalar], at index: Int) -> Int? {
        var cursor = index + 2
        while cursor + 1 < scalars.count {
            if scalars[cursor] == "$", scalars[cursor + 1] == "$" { return cursor + 2 }
            cursor += 1
        }
        return nil
    }

    // LETTER, `[a-zA-Z_$\u0080-\uffff]`, and DIGIT.
    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || scalar == "_" || scalar == "$"
            || (0x80...0xFFFF).contains(scalar.value)
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }
}
