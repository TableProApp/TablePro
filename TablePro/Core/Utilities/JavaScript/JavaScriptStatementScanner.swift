//
//  JavaScriptStatementScanner.swift
//  TablePro
//

import Foundation

/// Finds the top-level statements of a JavaScript program.
///
/// The SQL scanner splits on semicolons, which is right for SQL and wrong for JavaScript: the
/// semicolons inside a function body, a `for` header or an object literal are not statement
/// boundaries, so a mongosh script ran as several disconnected programs and lost its variables
/// between them.
///
/// The bias here is deliberately coarse. Merging two statements still runs correct code and only
/// costs a separate result; splitting one in half produces a syntax error. So a boundary is taken
/// only where the language guarantees one:
///
/// - a `;` at bracket depth zero,
/// - a `}` at depth zero that closes a statement opened by a statement keyword, unless what follows
///   continues it (`else`, `catch`, `finally`, `while`),
/// - a newline at depth zero where the next token cannot continue the expression, which is the
///   offending-token half of automatic semicolon insertion.
enum JavaScriptStatementScanner {
    struct Statement {
        let text: String
        let range: NSRange

        var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

        /// Whether the span holds anything to run. A trailing `// note` after a semicolon is a
        /// statement to the scanner and nothing at all to the engine, so counting it adds an empty
        /// result and a gutter control that runs nothing.
        var hasContent: Bool {
            !JavaScriptStatementScanner.strippingComments(text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
    }

    /// Keywords that open a statement whose closing brace ends it.
    private static let blockKeywords: Set<String> = [
        "if", "for", "while", "do", "switch", "try", "function", "class", "with", "label"
    ]

    /// Keywords that continue the statement the previous brace closed.
    private static let continuationKeywords: Set<String> = ["else", "catch", "finally", "while"]

    /// Comment text never runs, so a span holding only comments is not a statement to execute.
    static func strippingComments(_ text: String) -> String {
        let source = text as NSString
        var stripped = ""
        var index = 0
        while index < source.length {
            let character = Character(UnicodeScalar(source.character(at: index)) ?? " ")
            if character == "/", index + 1 < source.length {
                let next = Character(UnicodeScalar(source.character(at: index + 1)) ?? " ")
                if next == "/" {
                    index = endOfLineComment(source, from: index)
                    continue
                }
                if next == "*" {
                    index = endOfBlockComment(source, from: index)
                    continue
                }
            }
            stripped.append(character)
            index += 1
        }
        return stripped
    }

    /// Characters that can only continue the expression on the line before them, so a newline in
    /// front of one inserts no semicolon.
    private static let continuationStarters: Set<Character> = [
        ".", ",", ")", "]", "}", "+", "-", "*", "/", "%", "?", ":", "=", "<", ">", "!", "&", "|",
        "^", "~", "(", "["
    ]

    private static let continuationWords: Set<String> = ["in", "instanceof", "of"]

    /// Words that continue the construct on the line before them, so a newline in front of one
    /// inserts no semicolon. Allman-style JavaScript puts `{`, `else` and `catch` on their own
    /// lines, and splitting there produces two fragments that are each a syntax error.
    private static let openingWords: Set<String> = ["else", "catch", "finally", "while"]

    // MARK: - Public API

    /// Every statement in the document, including the empty and comment-only stretches, in order.
    static func locatedStatements(in source: String) -> [Statement] {
        scan(source)
    }

    /// The statements a run can execute, in order, with their spans.
    static func executableStatements(in source: String) -> [Statement] {
        scan(source).filter(\.hasContent)
    }

    /// The statement the caret sits in, or the last one when the caret is past the end.
    static func statementAtCursor(in source: String, cursorPosition: Int) -> Statement? {
        let statements = scan(source).filter(\.hasContent)
        guard !statements.isEmpty else { return nil }
        for statement in statements where cursorPosition <= statement.range.upperBound
            && cursorPosition >= statement.range.location {
            return statement
        }
        return statements.last { $0.range.location <= cursorPosition } ?? statements.first
    }

    // MARK: - Scanning

    private static func scan(_ source: String) -> [Statement] {
        let text = source as NSString
        guard text.length > 0 else { return [] }

        var statements: [Statement] = []
        var start = 0
        var index = 0
        var depth = 0
        var openedWithKeyword: [Bool] = []
        var lastMeaningful: Character?
        var lastWord = ""
        // The statement's own first word, which is what decides whether a brace closes it. The word
        // right before the brace cannot: `var f = function () {` and `function f() {` both read
        // `function` there, and only the second one ends at its `}`.
        var firstWord = ""
        var sawNewlineSinceMeaningful = false

        func closeStatement(endingAt end: Int) {
            let range = NSRange(location: start, length: end - start)
            guard range.length > 0 else { return }
            statements.append(Statement(text: text.substring(with: range), range: range))
            start = end
            lastMeaningful = nil
            lastWord = ""
            firstWord = ""
            sawNewlineSinceMeaningful = false
        }

        while index < text.length {
            let character = Character(UnicodeScalar(text.character(at: index)) ?? " ")

            if character == "/", index + 1 < text.length {
                let next = Character(UnicodeScalar(text.character(at: index + 1)) ?? " ")
                if next == "/" {
                    index = endOfLineComment(text, from: index)
                    continue
                }
                if next == "*" {
                    index = endOfBlockComment(text, from: index)
                    continue
                }
            }

            if character == "/", startsRegularExpression(after: lastMeaningful, word: lastWord) {
                index = endOfRegularExpression(text, from: index)
                lastMeaningful = "/"
                lastWord = ""
                sawNewlineSinceMeaningful = false
                continue
            }

            if character == "\"" || character == "'" {
                index = endOfString(text, from: index, quote: character)
                lastMeaningful = "\""
                lastWord = ""
                sawNewlineSinceMeaningful = false
                continue
            }

            if character == "`" {
                index = endOfTemplate(text, from: index)
                lastMeaningful = "`"
                lastWord = ""
                sawNewlineSinceMeaningful = false
                continue
            }

            if character.isNewline {
                sawNewlineSinceMeaningful = true
                index += 1
                continue
            }

            if character.isWhitespace {
                index += 1
                continue
            }

            if depth == 0, sawNewlineSinceMeaningful, insertsSemicolon(before: character, after: lastMeaningful) {
                let word = readWord(text, from: index)
                if !continuationWords.contains(word), !openingWords.contains(word),
                   !opensBlockOfCurrentStatement(character, firstWord: firstWord) {
                    closeStatement(endingAt: index)
                    depth = 0
                    openedWithKeyword.removeAll()
                }
            }

            switch character {
            case "(", "[":
                depth += 1
            case ")", "]":
                depth = max(0, depth - 1)
            case "{":
                openedWithKeyword.append(depth == 0 && blockKeywords.contains(firstWord))
                depth += 1
            case "}":
                depth = max(0, depth - 1)
                let closedBlock = openedWithKeyword.popLast() ?? false
                if depth == 0, closedBlock, !continuesAfterBrace(text, from: index + 1) {
                    lastMeaningful = "}"
                    lastWord = ""
                    closeStatement(endingAt: index + 1)
                    index += 1
                    continue
                }
            case ";":
                if depth == 0 {
                    closeStatement(endingAt: index + 1)
                    index += 1
                    continue
                }
            default:
                break
            }

            if isWordCharacter(character) {
                let word = readWord(text, from: index)
                if firstWord.isEmpty, depth == 0 { firstWord = word }
                lastWord = word
                lastMeaningful = character
                sawNewlineSinceMeaningful = false
                index += max(word.utf16.count, 1)
                continue
            }

            lastWord = ""
            lastMeaningful = character
            sawNewlineSinceMeaningful = false
            index += 1
        }

        closeStatement(endingAt: text.length)
        return statements
    }

    // MARK: - Boundary Rules

    /// Whether this `{` opens the body of the control statement already under way, as Allman
    /// bracing puts it on its own line.
    private static func opensBlockOfCurrentStatement(_ character: Character, firstWord: String) -> Bool {
        character == "{" && blockKeywords.contains(firstWord)
    }

    private static func insertsSemicolon(before next: Character, after previous: Character?) -> Bool {
        guard let previous else { return false }
        guard isExpressionEnd(previous) else { return false }
        return !continuationStarters.contains(next)
    }

    private static func isExpressionEnd(_ character: Character) -> Bool {
        character == ")" || character == "]" || character == "}" || character == "\""
            || character == "`" || character == "/" || isWordCharacter(character)
    }

    private static func continuesAfterBrace(_ text: NSString, from index: Int) -> Bool {
        var cursor = index
        while cursor < text.length {
            let character = Character(UnicodeScalar(text.character(at: cursor)) ?? " ")
            if character.isWhitespace {
                cursor += 1
                continue
            }
            if character == "/", cursor + 1 < text.length {
                let next = Character(UnicodeScalar(text.character(at: cursor + 1)) ?? " ")
                if next == "/" {
                    cursor = endOfLineComment(text, from: cursor)
                    continue
                }
                if next == "*" {
                    cursor = endOfBlockComment(text, from: cursor)
                    continue
                }
            }
            if continuationStarters.contains(character) { return true }
            return continuationKeywords.contains(readWord(text, from: cursor))
        }
        return false
    }

    /// Whether a `/` here opens a regular expression rather than dividing.
    ///
    /// The standard rule: a slash after something that can end an expression is division. `)` is
    /// treated as an expression end, which reads `if (x) /re/.test(y)` as division, exactly as
    /// every editor heuristic does; it costs nothing here because a mis-read regex only merges
    /// statements.
    private static func startsRegularExpression(after previous: Character?, word: String) -> Bool {
        guard let previous else { return true }
        if !word.isEmpty { return continuationWords.contains(word) || word == "return" || word == "typeof" }
        return !isExpressionEnd(previous)
    }

    // MARK: - Token Skipping

    private static func endOfLineComment(_ text: NSString, from index: Int) -> Int {
        var cursor = index
        while cursor < text.length, !Character(UnicodeScalar(text.character(at: cursor)) ?? " ").isNewline {
            cursor += 1
        }
        return cursor
    }

    private static func endOfBlockComment(_ text: NSString, from index: Int) -> Int {
        var cursor = index + 2
        while cursor + 1 < text.length {
            if text.character(at: cursor) == 0x2A, text.character(at: cursor + 1) == 0x2F {
                return cursor + 2
            }
            cursor += 1
        }
        return text.length
    }

    private static func endOfString(_ text: NSString, from index: Int, quote: Character) -> Int {
        var cursor = index + 1
        while cursor < text.length {
            let character = Character(UnicodeScalar(text.character(at: cursor)) ?? " ")
            if character == "\\" {
                cursor += 2
                continue
            }
            if character == quote { return cursor + 1 }
            if character.isNewline { return cursor }
            cursor += 1
        }
        return text.length
    }

    private static func endOfTemplate(_ text: NSString, from index: Int) -> Int {
        var cursor = index + 1
        var interpolation = 0
        while cursor < text.length {
            let character = Character(UnicodeScalar(text.character(at: cursor)) ?? " ")
            if character == "\\" {
                cursor += 2
                continue
            }
            if character == "$", cursor + 1 < text.length, text.character(at: cursor + 1) == 0x7B {
                interpolation += 1
                cursor += 2
                continue
            }
            if character == "}", interpolation > 0 {
                interpolation -= 1
                cursor += 1
                continue
            }
            if character == "`", interpolation == 0 { return cursor + 1 }
            cursor += 1
        }
        return text.length
    }

    private static func endOfRegularExpression(_ text: NSString, from index: Int) -> Int {
        var cursor = index + 1
        var inClass = false
        while cursor < text.length {
            let character = Character(UnicodeScalar(text.character(at: cursor)) ?? " ")
            if character == "\\" {
                cursor += 2
                continue
            }
            if character.isNewline { return cursor }
            if character == "[" { inClass = true }
            if character == "]" { inClass = false }
            if character == "/", !inClass {
                cursor += 1
                while cursor < text.length,
                      isWordCharacter(Character(UnicodeScalar(text.character(at: cursor)) ?? " ")) {
                    cursor += 1
                }
                return cursor
            }
            cursor += 1
        }
        return text.length
    }

    private static func readWord(_ text: NSString, from index: Int) -> String {
        var cursor = index
        var word = ""
        while cursor < text.length {
            let character = Character(UnicodeScalar(text.character(at: cursor)) ?? " ")
            guard isWordCharacter(character) else { break }
            word.append(character)
            cursor += 1
        }
        return word
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$"
    }
}
