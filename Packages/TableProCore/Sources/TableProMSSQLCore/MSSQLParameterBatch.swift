import Foundation

/// One value bound to a `?` placeholder, in the three shapes a cell can arrive in.
public enum MSSQLParameter: Equatable, Sendable {
    case null
    case text(String)
    case bytes(Data)
}

/// Rewrites a `?`-placeholder query into the `EXEC sp_executesql` form SQL Server takes, and
/// declares each parameter as the type its value actually is.
///
/// Every parameter used to be declared `NVARCHAR(MAX)` and assigned from the value's text. A
/// binary value has no text, so it was assigned `NULL`: a row matched on a `VARBINARY` column
/// found nothing, and the delete or update that followed reported success having touched no row.
/// A `VARBINARY(MAX)` parameter assigned a `0x…` literal is what that value is.
public enum MSSQLParameterBatch {
    public struct Statement: Equatable, Sendable {
        public let query: String
        public let declarations: String
        public let assignments: String

        public var isEmpty: Bool { declarations.isEmpty }
    }

    public static func spExecuteSql(query: String, parameters: [MSSQLParameter]) -> Statement {
        let replaced = replacePlaceholders(in: query, limit: parameters.count)
        guard replaced.count > 0 else {
            return Statement(query: replaced.query, declarations: "", assignments: "")
        }
        let used = parameters.prefix(replaced.count)
        let declarations = used.enumerated()
            .map { "@p\($0.offset + 1) \(declaredType(of: $0.element))" }
            .joined(separator: ", ")
        let assignments = used.enumerated()
            .map { "@p\($0.offset + 1) = \(literal(for: $0.element))" }
            .joined(separator: ", ")
        return Statement(query: replaced.query, declarations: declarations, assignments: assignments)
    }

    private static func declaredType(of parameter: MSSQLParameter) -> String {
        switch parameter {
        case .bytes:
            return "VARBINARY(MAX)"
        case .text, .null:
            return "NVARCHAR(MAX)"
        }
    }

    private static func literal(for parameter: MSSQLParameter) -> String {
        switch parameter {
        case .null:
            return "NULL"
        case .text(let value):
            return MSSQLStringLiteral.quoted(value)
        case .bytes(let data):
            return hexLiteral(data)
        }
    }

    /// `0x` on its own is the empty binary, which is what SQL Server writes for one and what it
    /// reads back. There is no zero-length form to special-case.
    private static func hexLiteral(_ data: Data) -> String {
        var literal = "0x"
        literal.reserveCapacity(2 + data.count * 2)
        for byte in data {
            literal.append(String(format: "%02X", byte))
        }
        return literal
    }

    /// A `?` inside a string literal or a quoted identifier is data, not a placeholder, and the
    /// doubled `''`, `""` and `]]` that carry one have to be stepped over rather than read as the
    /// end of the literal.
    ///
    /// The bracket is the one T-SQL spells differently from everything else, and it was missing:
    /// a column named `[we?ird]` took `@p1`, which shifted every parameter after it by one and
    /// sent the values to the wrong placeholders.
    private static func replacePlaceholders(in query: String, limit: Int) -> (query: String, count: Int) {
        var converted = ""
        var count = 0
        var quoting = Quoting.code
        let characters = Array(query)

        var index = 0
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil

            if let doubled = quoting.doubledDelimiter, character == doubled, next == doubled {
                converted.append(doubled)
                converted.append(doubled)
                index += 2
                continue
            }

            quoting = quoting.after(character)

            if character == "?", quoting == .code, count < limit {
                count += 1
                converted.append("@p\(count)")
            } else {
                converted.append(character)
            }
            index += 1
        }

        return (converted, count)
    }

    private enum Quoting {
        case code
        case singleQuote
        case doubleQuote
        case bracket

        /// What a doubled occurrence of this state's own delimiter escapes. A bracket identifier
        /// escapes its closing `]`, not the `[` that opened it.
        var doubledDelimiter: Character? {
            switch self {
            case .code: return nil
            case .singleQuote: return "'"
            case .doubleQuote: return "\""
            case .bracket: return "]"
            }
        }

        func after(_ character: Character) -> Quoting {
            switch self {
            case .code:
                switch character {
                case "'": return .singleQuote
                case "\"": return .doubleQuote
                case "[": return .bracket
                default: return .code
                }
            case .singleQuote:
                return character == "'" ? .code : self
            case .doubleQuote:
                return character == "\"" ? .code : self
            case .bracket:
                return character == "]" ? .code : self
            }
        }
    }
}
