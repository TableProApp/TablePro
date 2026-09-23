import Foundation

/// Whether a column's default also replaces a null the statement supplies, and on which statements.
public enum OracleDefaultOnNull: Sendable, Equatable {
    case never
    case onInsert
    case onInsertAndUpdate

    public init(onInsert: Bool, onUpdate: Bool) {
        guard onInsert else {
            self = .never
            return
        }
        self = onUpdate ? .onInsertAndUpdate : .onInsert
    }
}

/// One column's default as the app edits it: the exact SQL that follows the `DEFAULT` keyword, or nil for none.
///
/// `DATA_DEFAULT` keeps the text as it was typed, from its first token up to the comma or parenthesis that ended it, so
/// it carries the trailing whitespace and any comment written after the value (measured on 23ai: `7\n  `,
/// `9 -- trailing comment\n  `, `'A' /* active */\n  `). Both go: a line comment with its newline trimmed away would
/// comment out whatever a statement writes after the value.
///
/// An identity column stores its sequence there (`"HR"."ISEQ$$_73292".nextval`) and a virtual column its expression,
/// and neither is a default a `DEFAULT` clause can restate. A `DEFAULT ON NULL` column stores the value alone, and
/// restating that value as `DEFAULT 'x'` switches the semantics off and makes the column nullable (measured), so the
/// value comes back with its `ON NULL` in front of it, which is also what writes the column back as it is.
///
/// No default is SQL NULL, and an explicit `DEFAULT NULL` is the text `null` as typed, so the two stay apart: the
/// second comes back as `NULL`, the spelling the default menu offers.
///
/// `scripts/check-oracle-column-defaults.sh` re-measures every one of these shapes against a live server.
public struct OracleColumnDefault: Sendable, Equatable {
    public let storedText: String?
    public let isIdentity: Bool
    public let isVirtual: Bool
    public let onNull: OracleDefaultOnNull

    public init(storedText: String?, isIdentity: Bool, isVirtual: Bool, onNull: OracleDefaultOnNull) {
        self.storedText = storedText
        self.isIdentity = isIdentity
        self.isVirtual = isVirtual
        self.onNull = onNull
    }

    public var clause: String? {
        guard !isIdentity, !isVirtual, let storedText else { return nil }
        let value = OracleSQLCommentStripper(storedText).stripped().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let expression = value.caseInsensitiveCompare("NULL") == .orderedSame ? "NULL" : value
        switch onNull {
        case .never:
            return expression
        case .onInsert:
            return "ON NULL \(expression)"
        case .onInsertAndUpdate:
            return "ON NULL FOR INSERT AND UPDATE \(expression)"
        }
    }
}

/// Removes the comments from a fragment of Oracle SQL and leaves every literal and quoted name as it was, so a `--` or
/// `/*` inside `'...'`, `"..."` or an alternative-quoted `q'[...]'` is kept.
///
/// A line comment is removed up to its newline, which stays, and a block comment becomes one space, so the tokens on
/// either side of it stay apart.
internal struct OracleSQLCommentStripper {
    private let scalars: [Unicode.Scalar]

    internal init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    internal func stripped() -> String {
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            if startsComment(at: index, with: "-", "-") {
                index = lineEnd(from: index)
                continue
            }
            if startsComment(at: index, with: "/", "*") {
                index = blockCommentEnd(from: index + 2)
                output.append(" ")
                continue
            }
            let end = tokenEnd(from: index)
            output.append(contentsOf: scalars[index..<end])
            index = end
        }
        return String(output)
    }

    private func startsComment(at index: Int, with first: Unicode.Scalar, _ second: Unicode.Scalar) -> Bool {
        scalars[index] == first && index + 1 < scalars.count && scalars[index + 1] == second
    }

    private func lineEnd(from index: Int) -> Int {
        var cursor = index
        while cursor < scalars.count, scalars[cursor] != "\n" { cursor += 1 }
        return cursor
    }

    private func blockCommentEnd(from index: Int) -> Int {
        var cursor = index
        while cursor + 1 < scalars.count {
            if scalars[cursor] == "*", scalars[cursor + 1] == "/" { return cursor + 2 }
            cursor += 1
        }
        return scalars.count
    }

    private func tokenEnd(from index: Int) -> Int {
        switch scalars[index] {
        case "'" where opensAlternativeQuote(at: index):
            return alternativeQuoteEnd(from: index)
        case "'":
            return quotedEnd(from: index, delimiter: "'")
        case "\"":
            return quotedEnd(from: index, delimiter: "\"")
        default:
            return index + 1
        }
    }

    /// A doubled delimiter inside is the escape both string literals and quoted names use.
    private func quotedEnd(from open: Int, delimiter: Unicode.Scalar) -> Int {
        var cursor = open + 1
        while cursor < scalars.count {
            guard scalars[cursor] == delimiter else {
                cursor += 1
                continue
            }
            guard cursor + 1 < scalars.count, scalars[cursor + 1] == delimiter else { return cursor + 1 }
            cursor += 2
        }
        return scalars.count
    }

    /// `q'` or `nq'` at the start of a word opens a literal that ends at its delimiter's partner followed by `'`, and
    /// takes no escapes at all: `q'[it's -- x]'` is one literal.
    private func opensAlternativeQuote(at quote: Int) -> Bool {
        guard quote >= 1, Self.isAlternativeQuotePrefix(scalars[quote - 1]) else { return false }
        let beforePrefix = quote - 2
        guard beforePrefix >= 0 else { return true }
        guard Self.isNationalPrefix(scalars[beforePrefix]) else { return !Self.isWordScalar(scalars[beforePrefix]) }
        return beforePrefix == 0 || !Self.isWordScalar(scalars[beforePrefix - 1])
    }

    private func alternativeQuoteEnd(from quote: Int) -> Int {
        guard quote + 1 < scalars.count else { return scalars.count }
        let closing = Self.closingDelimiter(for: scalars[quote + 1])
        var cursor = quote + 2
        while cursor + 1 < scalars.count {
            if scalars[cursor] == closing, scalars[cursor + 1] == "'" { return cursor + 2 }
            cursor += 1
        }
        return scalars.count
    }

    private static func closingDelimiter(for opening: Unicode.Scalar) -> Unicode.Scalar {
        switch opening {
        case "[": "]"
        case "{": "}"
        case "(": ")"
        case "<": ">"
        default: opening
        }
    }

    private static func isAlternativeQuotePrefix(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "q" || scalar == "Q"
    }

    private static func isNationalPrefix(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "n" || scalar == "N"
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "$" || scalar == "#"
    }
}
