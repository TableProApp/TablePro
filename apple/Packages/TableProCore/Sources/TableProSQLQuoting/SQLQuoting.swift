// Every loop runs over Unicode scalars: servers lex by byte or scalar, and a quote followed by a
// combining mark is one Character, so a Character or default String search misses it.

public enum SQLIdentifierQuote: Sendable, Hashable {
    case doubleQuote
    case backtick
    case bracket

    var open: Unicode.Scalar {
        switch self {
        case .doubleQuote: "\""
        case .backtick: "`"
        case .bracket: "["
        }
    }

    var close: Unicode.Scalar {
        switch self {
        case .doubleQuote: "\""
        case .backtick: "`"
        case .bracket: "]"
        }
    }
}

public enum SQLStringEscapes: Sendable, Hashable {
    // A quote is doubled and nothing else is special. NUL is dropped: no such engine stores it in
    // text, and C clients end the statement at it.
    case standard
    // A backslash starts an escape. Doubles the backslash and the quote and writes every other scalar
    // as it is, which each such engine reads back, and a doubled quote stays one quote if the session
    // turns backslash escapes off. NUL is `\0`, or `\x00` before a digit, which Snowflake would read
    // as octal; ClickHouse, Snowflake and Databend decode both.
    case backslash
    // mysqldump's set: `\0 \b \n \r \t \Z`. MySQL has neither octal nor `\x`.
    case mysql
    // BigQuery and Spanner: a doubled quote is no escape there and `'''` opens a triple-quoted
    // literal, so every quote takes a backslash and every other control is written `\xhh`.
    case googleSQL

    public init(backslashEscapes: Bool, tripleQuotedStrings: Bool = false) {
        guard backslashEscapes else {
            self = .standard
            return
        }
        self = tripleQuotedStrings ? .googleSQL : .backslash
    }

    public var backslashEscapes: Bool {
        self != .standard
    }
}

public enum SQLQuoting {
    // `backslashEscapes` only where the engine's reading is settled, as for ClickHouse backticks: a
    // doubled closer is the spelling that holds under either reading.
    public static func identifier(
        _ name: String,
        quote: SQLIdentifierQuote = .doubleQuote,
        backslashEscapes: Bool = false
    ) -> String {
        var quoted = String.UnicodeScalarView()
        quoted.append(quote.open)
        for scalar in name.unicodeScalars {
            if backslashEscapes, scalar == "\\" || scalar == quote.close {
                quoted.append("\\")
            } else if scalar == quote.close {
                quoted.append(scalar)
            }
            quoted.append(scalar)
        }
        quoted.append(quote.close)
        return String(quoted)
    }

    // Databend before 1.2.945 ends a backtick name at the next backtick, so a name holding one goes in double
    // quotes. Its QuotedIdent keeps a backslash there as written, so only the quote is doubled: a backslash that
    // pairs with a quote makes the name fail to parse rather than name another object.
    public static func databendIdentifier(_ name: String) -> String {
        identifier(name, quote: name.unicodeScalars.contains("`") ? .doubleQuote : .backtick)
    }

    public static func stringLiteral(_ value: String, escapes: SQLStringEscapes = .standard) -> String {
        var quoted = String.UnicodeScalarView()
        quoted.append("'")
        appendLiteralBody(of: value, escapes: escapes, to: &quoted)
        quoted.append("'")
        return String(quoted)
    }

    public static func stringLiteralBody(_ value: String, escapes: SQLStringEscapes = .standard) -> String {
        var body = String.UnicodeScalarView()
        appendLiteralBody(of: value, escapes: escapes, to: &body)
        return String(body)
    }

    // The value of `text` when the whole of it is one `'…'` literal written with `escapes`, else nil.
    // The inverse of `stringLiteral`, for catalog text that may or may not be a literal.
    public static func decodedStringLiteral(_ text: String, escapes: SQLStringEscapes = .standard) -> String? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 2, scalars.first == "'", scalars.last == "'" else { return nil }
        var value = String.UnicodeScalarView()
        var index = 1
        let end = scalars.count - 1
        while index < end {
            let scalar = scalars[index]
            if scalar == "'" {
                guard escapes != .googleSQL, index + 1 < end, scalars[index + 1] == "'" else { return nil }
                value.append("'")
                index += 2
                continue
            }
            guard scalar == "\\", escapes.backslashEscapes else {
                value.append(scalar)
                index += 1
                continue
            }
            guard index + 1 < end else { return nil }
            let next = scalars[index + 1]
            if escapes == .googleSQL, next == "x" {
                guard index + 3 < end,
                      let byte = UInt8(String(String.UnicodeScalarView(scalars[(index + 2)...(index + 3)])), radix: 16)
                else { return nil }
                value.append(Unicode.Scalar(byte))
                index += 4
                continue
            }
            value.append(contentsOf: unescaped(next).unicodeScalars)
            index += 2
        }
        return String(value)
    }

    // The pattern still goes through `stringLiteral`, so with a backslash escape the backslashes
    // this adds are doubled again there, which is what such an engine reads back.
    public static func likePattern(
        _ value: String,
        escape: Unicode.Scalar = "\\",
        metacharacters: Set<Unicode.Scalar> = ["%", "_"]
    ) -> String {
        var pattern = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if scalar == escape || metacharacters.contains(scalar) {
                pattern.append(escape)
            }
            pattern.append(scalar)
        }
        return String(pattern)
    }

    // `$$body$$`, or nil when the body holds `$$` or ends in `$`, either of which closes it early.
    public static func dollarQuoted(_ body: String) -> String? {
        var previous: Unicode.Scalar?
        for scalar in body.unicodeScalars {
            if scalar == "$", previous == "$" { return nil }
            previous = scalar
        }
        guard previous != "$" else { return nil }
        return "$$" + body + "$$"
    }

    // Text written after `--`: no scalar any engine reads as a line end can end the comment early.
    public static func lineCommentText(_ text: String) -> String {
        var line = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}":
                line.append(" ")
            default:
                line.append(scalar)
            }
        }
        return String(line)
    }

    // MySQL's reading: `\%` and `\_` keep their backslash, any other unknown escape is the character.
    private static func unescaped(_ scalar: Unicode.Scalar) -> String {
        switch scalar {
        case "%", "_": "\\" + String(scalar)
        case "0": "\0"
        case "b": "\u{08}"
        case "n": "\n"
        case "r": "\r"
        case "t": "\t"
        case "Z": "\u{1A}"
        default: String(scalar)
        }
    }

    private static func appendLiteralBody(
        of value: String,
        escapes: SQLStringEscapes,
        to output: inout String.UnicodeScalarView
    ) {
        let scalars = Array(value.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            switch (scalar, escapes) {
            case (_, .googleSQL):
                appendGoogleSQLEscaped(scalar, to: &output)
            case ("'", _):
                output.append(contentsOf: "''".unicodeScalars)
            case ("\0", .standard):
                continue
            case (_, .standard):
                output.append(scalar)
            case ("\\", _):
                output.append(contentsOf: #"\\"#.unicodeScalars)
            case ("\0", .backslash) where index + 1 < scalars.count && ("0"..."9").contains(scalars[index + 1]):
                output.append(contentsOf: #"\x00"#.unicodeScalars)
            case ("\0", _):
                output.append(contentsOf: #"\0"#.unicodeScalars)
            case ("\u{08}", .mysql):
                output.append(contentsOf: #"\b"#.unicodeScalars)
            case ("\n", .mysql):
                output.append(contentsOf: #"\n"#.unicodeScalars)
            case ("\r", .mysql):
                output.append(contentsOf: #"\r"#.unicodeScalars)
            case ("\t", .mysql):
                output.append(contentsOf: #"\t"#.unicodeScalars)
            case ("\u{1A}", .mysql):
                output.append(contentsOf: #"\Z"#.unicodeScalars)
            default:
                output.append(scalar)
            }
        }
    }

    private static let hexDigits = Array("0123456789abcdef".unicodeScalars)

    private static func appendGoogleSQLEscaped(_ scalar: Unicode.Scalar, to output: inout String.UnicodeScalarView) {
        switch scalar {
        case "\\", "'", "\"", "`":
            output.append("\\")
            output.append(scalar)
        case "\n":
            output.append(contentsOf: #"\n"#.unicodeScalars)
        case "\r":
            output.append(contentsOf: #"\r"#.unicodeScalars)
        case "\t":
            output.append(contentsOf: #"\t"#.unicodeScalars)
        case _ where scalar.value < 0x20 || scalar.value == 0x7F:
            output.append(contentsOf: #"\x"#.unicodeScalars)
            output.append(hexDigits[Int(scalar.value >> 4)])
            output.append(hexDigits[Int(scalar.value & 0xF)])
        default:
            output.append(scalar)
        }
    }
}
