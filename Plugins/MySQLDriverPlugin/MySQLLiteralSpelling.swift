//
//  MySQLLiteralSpelling.swift
//  MySQLDriverPlugin
//

import Foundation

/// How a quoted string literal is spelled for the session that reads it.
///
/// A backslash escapes the character after it unless the session's `sql_mode` holds
/// `NO_BACKSLASH_ESCAPES`, where it is an ordinary character. No spelling of a backslash reads the
/// same both ways, measured on MySQL 8.4 and MariaDB 13: `'x\\y'` stores `x\y` in one mode and
/// `x\\y` in the other, and `COMMENT` rejects the hex literal that would sidestep it. The server
/// prints SQL with backslash escapes whatever the session's mode, in `SHOW CREATE TABLE`, a column's
/// type and MariaDB's catalog defaults alike, so that is how the plugin spells every literal it
/// holds. A statement it runs is re-spelled once, for the session that will read it, from the same
/// status flag `mysql_real_escape_string` reads to make the same choice.
internal enum MySQLLiteralSpelling: Equatable, Sendable {
    case backslashEscapes
    case quoteDoubling

    init(noBackslashEscapes: Bool?) {
        self = noBackslashEscapes == true ? .quoteDoubling : .backslashEscapes
    }

    /// The body of a single-quoted literal that reads back as `value`.
    func escaped(_ value: String) -> String {
        switch self {
        case .backslashEscapes:
            return mysqlEscapeStringLiteral(value)
        case .quoteDoubling:
            return value.replacingOccurrences(of: "'", with: "''")
        }
    }

    /// `sql`, spelled with backslash escapes, with every single-quoted literal in it spelled for
    /// this session instead. Identifiers, double-quoted text and comments are copied unchanged:
    /// a double-quoted span is an identifier under `ANSI_QUOTES`, and nothing the plugin writes
    /// puts a string there.
    func respelled(_ sql: String) -> String {
        guard self == .quoteDoubling else { return sql }
        let scalars = Array(sql.unicodeScalars)
        var output = String.UnicodeScalarView()
        output.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case "'":
                guard let literal = Self.backslashLiteral(in: scalars, openingAt: index) else {
                    output.append(contentsOf: scalars[index...])
                    index = scalars.count
                    continue
                }
                output.append("'")
                output.append(contentsOf: escaped(literal.value).unicodeScalars)
                output.append("'")
                index = literal.end
                continue
            case "`", "\"":
                let end = Self.endOfQuoted(in: scalars, openingAt: index)
                output.append(contentsOf: scalars[index..<end])
                index = end
                continue
            case "#":
                let end = Self.endOfLine(in: scalars, from: index)
                output.append(contentsOf: scalars[index..<end])
                index = end
                continue
            case "-" where Self.opensDashComment(scalars, at: index):
                let end = Self.endOfLine(in: scalars, from: index)
                output.append(contentsOf: scalars[index..<end])
                index = end
                continue
            case "/" where index + 1 < scalars.count && scalars[index + 1] == "*":
                let end = Self.endOfBlockComment(in: scalars, from: index)
                output.append(contentsOf: scalars[index..<end])
                index = end
                continue
            default:
                output.append(scalar)
                index += 1
            }
        }
        return String(output)
    }

    /// What a single-quoted literal spelled with backslash escapes reads as, and where it ends, or
    /// nil when it never closes. `\%` and `\_` keep their backslash, as the server keeps them
    /// outside a pattern, and any other escaped character stands for itself.
    private static func backslashLiteral(
        in scalars: [Unicode.Scalar],
        openingAt start: Int
    ) -> (value: String, end: Int)? {
        var value = String.UnicodeScalarView()
        var index = start + 1
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\", index + 1 < scalars.count {
                value.append(contentsOf: unescaped(scalars[index + 1]))
                index += 2
                continue
            }
            if scalar == "'" {
                guard index + 1 < scalars.count, scalars[index + 1] == "'" else {
                    return (String(value), index + 1)
                }
                value.append("'")
                index += 2
                continue
            }
            value.append(scalar)
            index += 1
        }
        return nil
    }

    private static func unescaped(_ scalar: Unicode.Scalar) -> [Unicode.Scalar] {
        switch scalar {
        case "0": return ["\u{00}"]
        case "b": return ["\u{08}"]
        case "n": return ["\n"]
        case "r": return ["\r"]
        case "t": return ["\t"]
        case "Z": return ["\u{1A}"]
        case "%", "_": return ["\\", scalar]
        default: return [scalar]
        }
    }

    private static func endOfQuoted(in scalars: [Unicode.Scalar], openingAt start: Int) -> Int {
        let quote = scalars[start]
        var index = start + 1
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\", quote != "`" {
                index += 2
                continue
            }
            index += 1
            guard scalar == quote else { continue }
            guard index < scalars.count, scalars[index] == quote else { return index }
            index += 1
        }
        return scalars.count
    }

    private static func opensDashComment(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        guard index + 1 < scalars.count, scalars[index + 1] == "-" else { return false }
        guard index + 2 < scalars.count else { return true }
        let next = scalars[index + 2]
        return next == " " || next == "\t" || next == "\n" || next == "\r"
    }

    private static func endOfLine(in scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start
        while index < scalars.count, scalars[index] != "\n" {
            index += 1
        }
        return index
    }

    private static func endOfBlockComment(in scalars: [Unicode.Scalar], from start: Int) -> Int {
        var index = start + 2
        while index + 1 < scalars.count {
            if scalars[index] == "*", scalars[index + 1] == "/" { return index + 2 }
            index += 1
        }
        return scalars.count
    }
}
