import Foundation

struct MongoShellFormatter: QueryFormatting {
    private static let indent = "  "
    private static let inlineWidthLimit = 60
    private static let maximumInputLength = 10_000_000

    private enum Token {
        case text(String)
        case string(String)
        case open(Character)
        case close(Character)
        case comma
        case colon
    }

    func format(_ text: String, cursorOffset: Int?) throws -> QueryFormatResult {
        let source = text as NSString
        guard source.length <= Self.maximumInputLength else {
            return QueryFormatResult(text: text, cursorOffset: cursorOffset)
        }

        let tokens = tokenize(source)
        let expansion = expansionFlags(for: tokens)
        return QueryFormatResult(text: emit(tokens, expansion: expansion), cursorOffset: nil)
    }

    private func tokenize(_ source: NSString) -> [Token] {
        var tokens: [Token] = []
        var pending = ""
        var index = 0

        func flushPending() {
            let trimmed = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { tokens.append(.text(trimmed)) }
            pending = ""
        }

        while index < source.length {
            let scalar = Character(UnicodeScalar(source.character(at: index)) ?? " ")

            if scalar == "\"" || scalar == "'" || scalar == "`" {
                flushPending()
                let literal = readStringLiteral(source, from: index, delimiter: scalar)
                tokens.append(.string(literal.value))
                index = literal.end
                continue
            }

            // A comment and a regular expression are single tokens. Letting the switch below see
            // inside one turns `/a{2,3}/` into `/a{2, 3}/`, which is a different pattern, and
            // breaks a `//` line across the reflow.
            if scalar == "/", index + 1 < source.length {
                let next = Character(UnicodeScalar(source.character(at: index + 1)) ?? " ")
                if next == "/" || next == "*" {
                    flushPending()
                    let comment = readComment(source, from: index, isBlock: next == "*")
                    tokens.append(.string(comment.value))
                    index = comment.end
                    continue
                }
            }

            if scalar == "/", startsRegularExpression(before: tokens, pending: pending) {
                flushPending()
                let literal = readRegularExpression(source, from: index)
                tokens.append(.string(literal.value))
                index = literal.end
                continue
            }

            switch scalar {
            case "{", "[":
                flushPending()
                tokens.append(.open(scalar))
            case "}", "]":
                flushPending()
                tokens.append(.close(scalar))
            case ",":
                flushPending()
                tokens.append(.comma)
            case ":":
                flushPending()
                tokens.append(.colon)
            default:
                pending.append(scalar)
            }

            index += 1
        }

        flushPending()
        return tokens
    }

    /// Whether a `/` here opens a regular expression rather than dividing.
    ///
    /// Division follows something that can end an expression, so a slash after an identifier, a
    /// number or a closing bracket is an operator.
    private func startsRegularExpression(before tokens: [Token], pending: String) -> Bool {
        if let last = pending.last(where: { !$0.isWhitespace }) {
            return !(last.isLetter || last.isNumber || last == "_" || last == ")" || last == "]")
        }
        guard let token = tokens.last else { return true }
        switch token {
        case .open, .comma, .colon: return true
        case .text, .string, .close: return false
        }
    }

    private func readRegularExpression(_ source: NSString, from start: Int) -> (value: String, end: Int) {
        var index = start + 1
        var inClass = false
        while index < source.length {
            let scalar = Character(UnicodeScalar(source.character(at: index)) ?? " ")
            if scalar == "\\" {
                index += 2
                continue
            }
            if scalar.isNewline { break }
            if scalar == "[" { inClass = true }
            if scalar == "]" { inClass = false }
            if scalar == "/", !inClass {
                index += 1
                while index < source.length {
                    let flag = Character(UnicodeScalar(source.character(at: index)) ?? " ")
                    guard flag.isLetter else { break }
                    index += 1
                }
                return (source.substring(with: NSRange(location: start, length: index - start)), index)
            }
            index += 1
        }
        return (source.substring(with: NSRange(location: start, length: index - start)), index)
    }

    private func readComment(_ source: NSString, from start: Int, isBlock: Bool) -> (value: String, end: Int) {
        var index = start + 2
        while index < source.length {
            let scalar = Character(UnicodeScalar(source.character(at: index)) ?? " ")
            if isBlock, scalar == "*", index + 1 < source.length,
               Character(UnicodeScalar(source.character(at: index + 1)) ?? " ") == "/" {
                index += 2
                break
            }
            if !isBlock, scalar.isNewline { break }
            index += 1
        }
        return (source.substring(with: NSRange(location: start, length: index - start)), index)
    }

    private func readStringLiteral(
        _ source: NSString,
        from start: Int,
        delimiter: Character
    ) -> (value: String, end: Int) {
        var value = String(delimiter)
        var index = start + 1
        let backslash = UInt16(UnicodeScalar("\\").value)
        let terminator = UInt16(String(delimiter).unicodeScalars.first?.value ?? 0)

        while index < source.length {
            let character = source.character(at: index)
            value.append(Character(UnicodeScalar(character) ?? " "))
            if character == backslash, index + 1 < source.length {
                value.append(Character(UnicodeScalar(source.character(at: index + 1)) ?? " "))
                index += 2
                continue
            }
            index += 1
            if character == terminator { break }
        }

        return (value, index)
    }

    private func expansionFlags(for tokens: [Token]) -> [Int: Bool] {
        var flags: [Int: Bool] = [:]
        var stack: [(index: Int, width: Int, hasNestedContainer: Bool)] = []

        for (index, token) in tokens.enumerated() {
            switch token {
            case .open:
                if !stack.isEmpty { stack[stack.count - 1].hasNestedContainer = true }
                stack.append((index, 0, false))
            case .close:
                guard let frame = stack.popLast() else { break }
                let expands = frame.hasNestedContainer || frame.width > Self.inlineWidthLimit
                flags[frame.index] = expands
                if !stack.isEmpty { stack[stack.count - 1].width += frame.width + 2 }
            case .text(let value), .string(let value):
                if !stack.isEmpty { stack[stack.count - 1].width += value.count }
            case .comma, .colon:
                if !stack.isEmpty { stack[stack.count - 1].width += 2 }
            }
        }

        return flags
    }

    private func emit(_ tokens: [Token], expansion: [Int: Bool]) -> String {
        var output = ""
        var depth = 0
        var expandedStack: [Bool] = []
        var atLineStart = true

        func newline() {
            output += "\n" + String(repeating: Self.indent, count: depth)
            atLineStart = true
        }

        for (index, token) in tokens.enumerated() {
            switch token {
            case .open(let character):
                let expands = expansion[index] ?? false
                output.append(character)
                expandedStack.append(expands)
                if expands {
                    depth += 1
                    newline()
                }
            case .close(let character):
                let expands = expandedStack.popLast() ?? false
                if expands {
                    depth = max(0, depth - 1)
                    newline()
                }
                output.append(character)
                atLineStart = false
            case .comma:
                output.append(",")
                if expandedStack.last == true {
                    newline()
                } else {
                    output.append(" ")
                    atLineStart = false
                }
            case .colon:
                output.append(": ")
                atLineStart = false
            case .text(let value), .string(let value):
                if !atLineStart, needsSpace(before: value, in: output) { output.append(" ") }
                output.append(value)
                atLineStart = false
            }
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func needsSpace(before value: String, in output: String) -> Bool {
        guard let last = output.last, let first = value.first else { return false }
        if last == "(" || first == ")" || first == "." || last == "." { return false }
        if last == " " || last == "\n" { return false }
        return true
    }
}
