import Foundation

internal struct SpannerSQLCursor {
    private let text: Substring
    private let nestsBlockComments: Bool
    private var position: String.Index

    init(_ sql: String, nestsBlockComments: Bool = false) {
        self.text = sql[...]
        self.nestsBlockComments = nestsBlockComments
        self.position = sql.startIndex
    }

    var peek: Unicode.Scalar? {
        position < text.endIndex ? text.unicodeScalars[position] : nil
    }

    var remainder: Substring {
        text[position...]
    }

    var isAtStatementEnd: Bool {
        var cursor = self
        while true {
            cursor.skipNoise(skippingHints: false)
            guard cursor.peek == ";" else { break }
            cursor.advance()
        }
        return cursor.peek == nil
    }

    mutating func advance() {
        guard position < text.endIndex else { return }
        position = text.unicodeScalars.index(after: position)
    }

    mutating func skipNoise(skippingHints: Bool) {
        while let scalar = peek {
            if scalar.properties.isWhitespace {
                advance()
            } else if scalar == "-", next == "-" {
                skipLineComment()
            } else if scalar == "#" {
                skipLineComment()
            } else if scalar == "/", next == "*" {
                skipBlockComment()
            } else if skippingHints, scalar == "@", next == "{" {
                skipHint()
            } else {
                return
            }
        }
    }

    mutating func readWord() -> String? {
        guard let first = peek, Self.isWordStart(first) else { return nil }
        let start = position
        while let scalar = peek, Self.isWordContinuation(scalar) {
            advance()
        }
        return String(text[start..<position])
    }

    mutating func readPath() -> [String]? {
        guard let first = readIdentifierPart() else { return nil }
        var parts = [first]
        while peek == "." {
            advance()
            guard let part = readIdentifierPart() else { return nil }
            parts.append(part)
        }
        return parts
    }

    private mutating func readIdentifierPart() -> String? {
        switch peek {
        case "`":
            return readBacktickIdentifier()
        case "\"":
            return readDoubleQuotedIdentifier()
        default:
            return readBareIdentifier()
        }
    }

    private mutating func readBareIdentifier() -> String? {
        let start = position
        while let scalar = peek, Self.isBareIdentifierScalar(scalar) {
            advance()
        }
        return start == position ? nil : String(text[start..<position])
    }

    private mutating func readBacktickIdentifier() -> String? {
        advance()
        var name = String.UnicodeScalarView()
        while let scalar = peek {
            advance()
            if scalar == "`" { return String(name) }
            guard scalar == "\\", let escaped = peek else {
                name.append(scalar)
                continue
            }
            advance()
            name.append(Self.unescaped(escaped))
        }
        return nil
    }

    private mutating func readDoubleQuotedIdentifier() -> String? {
        advance()
        var name = String.UnicodeScalarView()
        while let scalar = peek {
            advance()
            guard scalar == "\"" else {
                name.append(scalar)
                continue
            }
            guard peek == "\"" else { return String(name) }
            advance()
            name.append("\"")
        }
        return nil
    }

    private static func unescaped(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar {
        case "n": "\n"
        case "r": "\r"
        case "t": "\t"
        default: scalar
        }
    }

    private static func isBareIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "_" || scalar == "$"
    }

    private var next: Unicode.Scalar? {
        guard position < text.endIndex else { return nil }
        let following = text.unicodeScalars.index(after: position)
        return following < text.endIndex ? text.unicodeScalars[following] : nil
    }

    private mutating func skipLineComment() {
        while let scalar = peek, scalar != "\n", scalar != "\r" {
            advance()
        }
    }

    private mutating func skipBlockComment() {
        advance()
        advance()
        var depth = 1
        while let scalar = peek {
            if scalar == "*", next == "/" {
                advance()
                advance()
                depth -= 1
                if depth == 0 { return }
            } else if nestsBlockComments, scalar == "/", next == "*" {
                advance()
                advance()
                depth += 1
            } else {
                advance()
            }
        }
    }

    private mutating func skipHint() {
        while let scalar = peek {
            advance()
            if scalar == "}" { return }
        }
    }

    private static func isWordStart(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || scalar == "_")
    }

    private static func isWordContinuation(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "_")
    }
}
