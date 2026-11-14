import Foundation
import TableProSQLGrammar

/// Structural scan shared by the diagnostic producers. Reports only what more typing cannot fix:
/// a closer with no opener, and an unterminated block comment. A missing closer is treated as
/// "still typing" and never reported, which is what keeps the editor quiet while you work.
enum QueryBracketScanner {
    struct Result {
        let unmatchedClose: NSRange?
        let unterminatedComment: NSRange?
        let hasUnclosedOpener: Bool
        let hasUnterminatedString: Bool
    }

    private static let openParen = UInt16(UnicodeScalar("(").value)
    private static let closeParen = UInt16(UnicodeScalar(")").value)
    private static let openBrace = UInt16(UnicodeScalar("{").value)
    private static let closeBrace = UInt16(UnicodeScalar("}").value)
    private static let openBracket = UInt16(UnicodeScalar("[").value)
    private static let closeBracket = UInt16(UnicodeScalar("]").value)
    private static let backslash = UInt16(UnicodeScalar("\\").value)
    private static let slash = UInt16(UnicodeScalar("/").value)
    private static let star = UInt16(UnicodeScalar("*").value)
    private static let newline = UInt16(UnicodeScalar("\n").value)
    private static let singleQuote = UInt16(UnicodeScalar("'").value)
    private static let doubleQuote = UInt16(UnicodeScalar("\"").value)
    private static let backtick = UInt16(UnicodeScalar("`").value)

    // `--` is JavaScript's decrement operator: read as a comment it would hide the rest of the line.
    enum Language {
        case sql(SQLLexicalGrammar)
        case javaScript
    }

    static func scan(_ text: NSString, language: Language) -> Result {
        switch language {
        case .sql(let grammar):
            return scanSQL(text, grammar: grammar)
        case .javaScript:
            return scanJavaScript(text)
        }
    }

    private struct Brackets {
        var stack: [UInt16] = []
        var unmatchedClose: NSRange?

        mutating func read(_ character: UInt16, at index: Int) {
            switch character {
            case openParen, openBrace, openBracket:
                stack.append(character)
            case closeParen, closeBrace, closeBracket:
                if stack.last == QueryBracketScanner.opener(for: character) {
                    stack.removeLast()
                } else if unmatchedClose == nil {
                    unmatchedClose = NSRange(location: index, length: 1)
                }
            default:
                break
            }
        }
    }

    private static func scanSQL(_ text: NSString, grammar: SQLLexicalGrammar) -> Result {
        var brackets = Brackets()
        var unterminatedComment: NSRange?
        var hasUnterminatedString = false
        var index = 0

        while index < text.length {
            let character = text.character(at: index)
            guard SQLNonCodeSpan.mayStart(character),
                  let span = SQLNonCodeSpan.span(at: index, in: text, grammar: grammar)
            else {
                brackets.read(character, at: index)
                index += 1
                continue
            }
            switch span.kind {
            case .lineComment, .parameter:
                break
            case .blockComment, .executableComment:
                if !span.isTerminated {
                    unterminatedComment = NSRange(location: span.start, length: 2)
                }
            case .quoted:
                hasUnterminatedString = hasUnterminatedString || !span.isTerminated
            }
            // The server runs the body of `/*! ... */`, so its brackets are code.
            if span.kind == .executableComment,
               let opener = SqlLexer.executableCommentOpenerLength(text, at: index, length: text.length) {
                index += opener
                continue
            }
            index = max(span.end, index + 1)
        }

        return Result(
            unmatchedClose: brackets.unmatchedClose,
            unterminatedComment: unterminatedComment,
            hasUnclosedOpener: !brackets.stack.isEmpty,
            hasUnterminatedString: hasUnterminatedString
        )
    }

    private static func scanJavaScript(_ text: NSString) -> Result {
        var brackets = Brackets()
        var commentStart: Int?
        var stringDelimiter: UInt16 = 0
        var isInBlockComment = false
        var isInLineComment = false
        var index = 0

        while index < text.length {
            let character = text.character(at: index)

            if isInLineComment {
                if character == newline { isInLineComment = false }
                index += 1
                continue
            }

            if isInBlockComment {
                if character == star, index + 1 < text.length, text.character(at: index + 1) == slash {
                    isInBlockComment = false
                    commentStart = nil
                    index += 2
                    continue
                }
                index += 1
                continue
            }

            if stringDelimiter != 0 {
                if character == backslash {
                    index += 2
                    continue
                }
                if character == stringDelimiter { stringDelimiter = 0 }
                index += 1
                continue
            }

            if character == slash, index + 1 < text.length {
                let next = text.character(at: index + 1)
                if next == star {
                    isInBlockComment = true
                    commentStart = index
                    index += 2
                    continue
                }
                if next == slash {
                    isInLineComment = true
                    index += 2
                    continue
                }
            }

            if character == singleQuote || character == doubleQuote || character == backtick {
                stringDelimiter = character
                index += 1
                continue
            }

            brackets.read(character, at: index)
            index += 1
        }

        return Result(
            unmatchedClose: brackets.unmatchedClose,
            unterminatedComment: isInBlockComment ? commentStart.map { NSRange(location: $0, length: 2) } : nil,
            hasUnclosedOpener: !brackets.stack.isEmpty,
            hasUnterminatedString: stringDelimiter != 0
        )
    }

    private static func opener(for closer: UInt16) -> UInt16 {
        switch closer {
        case closeParen: return openParen
        case closeBrace: return openBrace
        default: return openBracket
        }
    }
}
