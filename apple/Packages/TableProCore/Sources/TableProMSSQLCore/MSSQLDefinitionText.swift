import Foundation
import TableProSQLGrammar

// T-SQL needs no `;` before the next statement, so catalog or user text written into DDL has to stay inside the
// clause it lands in: an expression as one parenthesized group, the form the catalog stores it in, and a type as one
// name with at most one argument group.
public enum MSSQLDefinitionText {
    private static let databaseTypeId = "SQL Server"
    private static let openParenthesis = UInt16(UnicodeScalar("(").value)
    private static let openBracket = UInt16(UnicodeScalar("[").value)
    private static let period = UInt16(UnicodeScalar(".").value)
    private static let identifierSymbols: Set<UInt16> = Set("_@#$".utf16)
    private static let referentialActions: Set<String> = ["NO ACTION", "CASCADE", "SET NULL", "SET DEFAULT"]
    private static let indexKinds: Set<String> = ["CLUSTERED", "NONCLUSTERED"]
    // The ISO spellings SQL Server documents as synonyms, the one place a type takes a second word.
    private static let multiWordTypes: Set<[String]> = [
        ["DOUBLE", "PRECISION"], ["CHARACTER", "VARYING"], ["CHAR", "VARYING"], ["NATIONAL", "CHARACTER"],
        ["NATIONAL", "CHAR"], ["NATIONAL", "CHARACTER", "VARYING"], ["NATIONAL", "CHAR", "VARYING"],
        ["NATIONAL", "TEXT"], ["BINARY", "VARYING"],
    ]
    private static let longestMultiWordType = 3

    public static func isParenthesizedExpression(_ text: String) -> Bool {
        SQLExpressionFragment.isSingleExpression(text, databaseTypeId: databaseTypeId)
    }

    // A default, computed column, check or index filter: `text` when it is one parenthesized group, else inside a
    // pair of its own, and nil when it reaches past that pair either way.
    public static func expression(_ text: String) -> String? {
        if isParenthesizedExpression(text) { return text }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let wrapped = "(" + text + ")"
        return isParenthesizedExpression(wrapped) ? wrapped : nil
    }

    // `int`, `nvarchar(max)`, `decimal(18,2)`, `[dbo].[Money]`: a second word outside the group would start a statement.
    public static func isColumnType(_ text: String) -> Bool {
        let source = text as NSString
        let length = source.length
        var index = skippingWhitespace(in: source, from: 0)
        if let end = multiWordTypeEnd(in: source, from: index) {
            index = end
        } else {
            while true {
                guard let end = nameEnd(in: source, at: index) else { return false }
                index = end
                guard index < length, source.character(at: index) == period else { break }
                index += 1
            }
        }
        index = skippingWhitespace(in: source, from: index)
        guard index < length else { return true }
        guard source.character(at: index) == openParenthesis else { return false }
        return SQLExpressionFragment.isSingleType(source.substring(from: index), databaseTypeId: databaseTypeId)
    }

    public static func isCollationName(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_"
        }
    }

    // `seed,increment` as `sys.identity_columns` reads back, each a whole number.
    public static func isIdentitySpecification(_ text: String) -> Bool {
        let parts = text.unicodeScalars.split(separator: ",", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            let digits = part.first == "-" || part.first == "+" ? part.dropFirst() : part[...]
            return !digits.isEmpty && digits.allSatisfy { ("0"..."9").contains($0) }
        }
    }

    // SQL Server has no RESTRICT; NO ACTION is the same check.
    public static func referentialAction(_ text: String) -> String? {
        let action = text.uppercased()
        if action == "RESTRICT" { return "NO ACTION" }
        return referentialActions.contains(action) ? action : nil
    }

    public static func indexKind(_ text: String?) -> String? {
        guard let kind = text?.uppercased(), indexKinds.contains(kind) else { return nil }
        return kind
    }

    private static func skippingWhitespace(in source: NSString, from start: Int) -> Int {
        var index = start
        while index < source.length, SqlLexer.isWhitespace(source.character(at: index)) {
            index += 1
        }
        return index
    }

    // Where an allowlisted spelling such as `national character varying` ends, its words ASCII and apart by whitespace.
    private static func multiWordTypeEnd(in source: NSString, from start: Int) -> Int? {
        var words: [(word: String, end: Int)] = []
        var index = start
        while words.count < longestMultiWordType {
            if !words.isEmpty {
                let next = skippingWhitespace(in: source, from: index)
                guard next > index else { break }
                index = next
            }
            guard let end = wordEnd(in: source, at: index) else { break }
            let word = source.substring(with: NSRange(location: index, length: end - index))
            guard word.unicodeScalars.allSatisfy({ $0.isASCII }) else { break }
            words.append((word.uppercased(), end))
            index = end
        }
        for count in stride(from: words.count, through: 2, by: -1)
        where multiWordTypes.contains(words.prefix(count).map { $0.word }) {
            return words[count - 1].end
        }
        return nil
    }

    // One part of a name: `[a]]b]`, `"a""b"` or a regular identifier.
    private static func nameEnd(in source: NSString, at index: Int) -> Int? {
        guard index < source.length else { return nil }
        let opener = source.character(at: index)
        if opener == openBracket || opener == SqlLexer.doubleQuote {
            guard let span = SQLNonCodeSpan.span(at: index, in: source, grammar: SQLLexicalProfile.sqlServer),
                  span.kind == .quoted, span.isTerminated
            else { return nil }
            return span.end
        }
        return wordEnd(in: source, at: index)
    }

    // SQL Server reads U+0085, U+2028 and other non-ASCII spaces as whitespace, so outside ASCII only a letter goes on.
    private static func wordEnd(in source: NSString, at index: Int) -> Int? {
        var end = index
        while end < source.length {
            let unit = source.character(at: end)
            if unit < 0x80 {
                guard SQLNonCodeSpan.isWordUnit(unit) || identifierSymbols.contains(unit) else { break }
                end += 1
                continue
            }
            guard let scalar = unicodeScalar(in: source, at: end), scalar.properties.isAlphabetic else { break }
            end += scalar.utf16.count
        }
        return end > index ? end : nil
    }

    private static func unicodeScalar(in source: NSString, at index: Int) -> Unicode.Scalar? {
        let unit = source.character(at: index)
        if let scalar = Unicode.Scalar(unit) { return scalar }
        guard UTF16.isLeadSurrogate(unit), index + 1 < source.length else { return nil }
        let trail = source.character(at: index + 1)
        guard UTF16.isTrailSurrogate(trail) else { return nil }
        return Unicode.Scalar(0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(trail) - 0xDC00))
    }
}

public struct MSSQLDefinitionRefusal: Error, LocalizedError, Sendable, Equatable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var errorDescription: String? { reason }

    public static func columnDefault(_ column: String) -> MSSQLDefinitionRefusal {
        MSSQLDefinitionRefusal(reason: String(
            format: String(localized: "The default of column %@ is not one SQL expression, so it cannot be written."),
            column
        ))
    }

    public static func columnType(_ column: String, _ type: String) -> MSSQLDefinitionRefusal {
        MSSQLDefinitionRefusal(reason: String(
            format: String(localized: "The type of column %@ is not one SQL Server type: %@"),
            column,
            type
        ))
    }

    public static func computedColumn(_ column: String) -> MSSQLDefinitionRefusal {
        MSSQLDefinitionRefusal(reason: String(
            format: String(localized: "The computed expression of column %@ is not one SQL expression, so it cannot be written."),
            column
        ))
    }

    public static func collation(_ column: String, _ collation: String) -> MSSQLDefinitionRefusal {
        MSSQLDefinitionRefusal(reason: String(
            format: String(localized: "The collation of column %@ is not a collation name: %@"),
            column,
            collation
        ))
    }

    public static func identity(_ column: String, _ identity: String) -> MSSQLDefinitionRefusal {
        MSSQLDefinitionRefusal(reason: String(
            format: String(localized: "The identity of column %@ is not a whole-number seed and increment: %@"),
            column,
            identity
        ))
    }

    public static func checkConstraint(_ object: String) -> MSSQLDefinitionRefusal {
        MSSQLDefinitionRefusal(reason: String(
            format: String(localized: "A check constraint of %@ is not one SQL expression, so it cannot be written."),
            object
        ))
    }

    public static func indexFilter(_ index: String) -> MSSQLDefinitionRefusal {
        MSSQLDefinitionRefusal(reason: String(
            format: String(localized: "The filter of index %@ is not one SQL expression, so it cannot be written."),
            index
        ))
    }
}
