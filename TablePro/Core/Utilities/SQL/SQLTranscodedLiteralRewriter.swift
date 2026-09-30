//
//  SQLTranscodedLiteralRewriter.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

internal enum SQLTranscodedLiteralError: Error, Equatable {
    case unrecoverableBinaryLiteral
}

internal enum SQLTranscodedLiteralRewriter {
    private struct Introducer {
        let range: NSRange
        let characterSet: String
    }

    private struct Replacement {
        let range: NSRange
        let text: String
    }

    private enum SQLModeAssignment {
        case literal(String)
        case unknown
    }

    private struct LiteralContext {
        let encoding: String.Encoding
        let backslashEscapesAreOn: Bool
        let grammar: SQLLexicalGrammar
    }

    private static let underscore = UInt16(UnicodeScalar("_").value)
    private static let unicodeCharacterSets: Set<String> = ["utf8", "utf8mb4", "utf8mb3"]
    private static let binaryCharacterSet = "binary"
    private static let exactlyRecoverableEncodings: Set<String.Encoding> = [.isoLatin1, .windowsCP1252]
    private static let escapedBytes: [UInt8: UInt8] = [
        UInt8(ascii: "0"): 0x00, UInt8(ascii: "b"): 0x08, UInt8(ascii: "n"): 0x0A,
        UInt8(ascii: "r"): 0x0D, UInt8(ascii: "t"): 0x09, UInt8(ascii: "Z"): 0x1A
    ]
    private static let backslash = UInt8(ascii: "\\")
    private static let noBackslashEscapes = "NO_BACKSLASH_ESCAPES"
    private static let sqlModeVariable = "SQL_MODE"
    private static let sessionScopes: Set<String> = ["SESSION", "LOCAL"]
    private static let serverScopes: Set<String> = ["GLOBAL", "PERSIST", "PERSIST_ONLY"]
    private static let percent = UInt8(ascii: "%")

    internal static func rewritten(
        _ statement: String,
        decodedFrom encoding: String.Encoding,
        backslashEscapesAreOn: Bool = true,
        grammar: SQLLexicalGrammar
    ) throws -> String? {
        let text = statement as NSString
        guard text.range(of: "_").location != NSNotFound else { return nil }
        let context = LiteralContext(encoding: encoding, backslashEscapesAreOn: backslashEscapesAreOn, grammar: grammar)
        let replacements = try literalReplacements(in: text, context: context)
        guard !replacements.isEmpty else { return nil }
        let result = NSMutableString(string: text)
        for replacement in replacements.reversed() {
            result.replaceCharacters(in: replacement.range, with: replacement.text)
        }
        return result as String
    }

    private static func literalReplacements(in text: NSString, context: LiteralContext) throws -> [Replacement] {
        let grammar = context.grammar
        let length = text.length
        var replacements: [Replacement] = []
        var introducer: Introducer?
        var index = 0
        while index < length {
            let character = text.character(at: index)
            if SqlLexer.isWhitespace(character) {
                index += 1
                continue
            }
            if let opener = SqlLexer.executableCommentOpenerLength(text, at: index, length: length) {
                introducer = nil
                index += opener
                continue
            }
            if let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar) {
                if span.kind == .quoted, isStringQuote(text.character(at: span.start)), let pending = introducer,
                   let replacement = try replacement(for: pending, literal: span, in: text, context: context) {
                    replacements.append(replacement)
                }
                if !span.kind.isComment {
                    introducer = nil
                }
                index = max(span.end, index + 1)
                continue
            }
            guard SQLNonCodeSpan.isWordUnit(character) else {
                introducer = nil
                index += 1
                continue
            }
            let wordStart = index
            while index < length, SQLNonCodeSpan.isWordUnit(text.character(at: index)) {
                index += 1
            }
            introducer = introducerWord(in: text, range: NSRange(location: wordStart, length: index - wordStart))
        }
        return replacements
    }

    internal static func backslashEscapesAreOn(
        after statement: String,
        currently isOn: Bool,
        grammar: SQLLexicalGrammar
    ) -> Bool {
        let text = statement as NSString
        guard text.range(of: "sql_mode", options: .caseInsensitive).location != NSNotFound else { return isOn }
        var cursor = SQLTokenCursor(text, grammar: grammar)
        guard cursor.next()?.word == "SET" else { return isOn }
        var result = isOn
        var listIsServerScoped = false
        var head = cursor.next()
        while let token = head {
            switch sessionSQLMode(startingAt: token, cursor: &cursor, in: text, listIsServerScoped: &listIsServerScoped) {
            case .literal(let mode):
                result = !mode.uppercased().contains(noBackslashEscapes)
            case .unknown:
                result = false
            case nil:
                break
            }
            head = nextElementHead(&cursor)
        }
        return result
    }

    private static func sessionSQLMode(
        startingAt token: SQLTokenCursor.Token,
        cursor: inout SQLTokenCursor,
        in text: NSString,
        listIsServerScoped: inout Bool
    ) -> SQLModeAssignment? {
        var current = token
        while let word = current.word, sessionScopes.contains(word) || serverScopes.contains(word) {
            listIsServerScoped = serverScopes.contains(word)
            guard let next = cursor.next() else { return nil }
            current = next
        }
        guard let name = current.identifier else { return nil }
        switch name {
        case sqlModeVariable:
            guard !listIsServerScoped else { return nil }
        case "@@" + sqlModeVariable:
            break
        case "@@SESSION", "@@LOCAL":
            guard cursor.next()?.isSymbol(SQLTokenCursor.period) == true,
                  cursor.next()?.identifier == sqlModeVariable else { return nil }
        default:
            return nil
        }
        guard cursor.next()?.isSymbol(SQLTokenCursor.equals) == true, let value = cursor.next() else { return nil }
        let range = cursor.tokenRange
        switch value {
        case .literal where range.length >= 2:
            return .literal(text.substring(with: NSRange(location: range.location + 1, length: range.length - 2)))
        case .word("DEFAULT"):
            return .literal("")
        default:
            return .unknown
        }
    }

    private static func nextElementHead(_ cursor: inout SQLTokenCursor) -> SQLTokenCursor.Token? {
        while let token = cursor.next() {
            if token.isSymbol(SQLTokenCursor.comma), cursor.parenDepth == 0 {
                return cursor.next()
            }
        }
        return nil
    }

    private static func introducerWord(in text: NSString, range: NSRange) -> Introducer? {
        guard range.length > 1, text.character(at: range.location) == underscore else { return nil }
        let name = text.substring(with: NSRange(location: range.location + 1, length: range.length - 1)).lowercased()
        return Introducer(range: range, characterSet: name)
    }

    private static func isStringQuote(_ character: UInt16) -> Bool {
        character == SqlLexer.singleQuote || character == SqlLexer.doubleQuote
    }

    private static func replacement(
        for introducer: Introducer,
        literal span: SQLNonCodeSpan.Span,
        in text: NSString,
        context: LiteralContext
    ) throws -> Replacement? {
        let body = text.substring(with: NSRange(location: span.start + 1, length: max(0, span.contentEnd - span.start - 1)))
        guard !unicodeCharacterSets.contains(introducer.characterSet),
              body.unicodeScalars.contains(where: { !$0.isASCII }) else {
            return nil
        }
        guard introducer.characterSet == binaryCharacterSet else {
            guard isFollowedByCollate(span.end, in: text, grammar: context.grammar) else {
                return Replacement(range: introducer.range, text: "_utf8mb4")
            }
            let literal = text.substring(with: NSRange(location: span.start, length: span.end - span.start))
            let range = NSRange(location: introducer.range.location, length: span.end - introducer.range.location)
            return Replacement(range: range, text: "CONVERT(_utf8mb4\(literal) USING \(introducer.characterSet))")
        }
        guard exactlyRecoverableEncodings.contains(context.encoding),
              context.backslashEscapesAreOn || !body.contains("\\"),
              let bytes = body.data(using: context.encoding) else {
            throw SQLTranscodedLiteralError.unrecoverableBinaryLiteral
        }
        let quote = UInt8(truncatingIfNeeded: text.character(at: span.start))
        let hex = unescaped([UInt8](bytes), quote: quote).map { String(format: "%02X", $0) }.joined()
        let range = NSRange(location: introducer.range.location, length: span.end - introducer.range.location)
        return Replacement(range: range, text: "X'\(hex)'")
    }

    private static func isFollowedByCollate(_ offset: Int, in text: NSString, grammar: SQLLexicalGrammar) -> Bool {
        var index = offset
        while index < text.length {
            if SqlLexer.isWhitespace(text.character(at: index)) {
                index += 1
                continue
            }
            guard let comment = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar), comment.kind.isComment else { break }
            index = max(comment.end, index + 1)
        }
        let keyword = "COLLATE"
        let keywordLength = (keyword as NSString).length
        guard index + keywordLength <= text.length,
              text.substring(with: NSRange(location: index, length: keywordLength)).uppercased() == keyword else {
            return false
        }
        return index + keywordLength == text.length
            || !SQLNonCodeSpan.isWordUnit(text.character(at: index + keywordLength))
    }

    private static func unescaped(_ bytes: [UInt8], quote: UInt8) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == quote, index + 1 < bytes.count, bytes[index + 1] == quote {
                result.append(quote)
                index += 2
                continue
            }
            guard byte == backslash, index + 1 < bytes.count else {
                result.append(byte)
                index += 1
                continue
            }
            let escaped = bytes[index + 1]
            if escaped == percent || escaped == UInt8(ascii: "_") {
                result.append(contentsOf: [backslash, escaped])
            } else {
                result.append(escapedBytes[escaped] ?? escaped)
            }
            index += 2
        }
        return result
    }
}
