import Foundation
import TableProSQLGrammar

/// The object name a stored module's `CREATE` header declares.
///
/// SQL Server keeps the batch that created a view, routine or trigger as it was sent, and `sp_rename` renames the
/// object without touching that text. Measured on Azure SQL Edge 15.0: after `sp_rename 'dbo.v_old', 'v_new'` the
/// definition still reads `CREATE VIEW dbo.v_old AS ...`, so the text read back creates the old name. SSMS rewrites
/// the name in the header when it scripts the object, and so does this. The header is found with the shared lexer,
/// because the stored batch keeps its leading comments, and a comment can read `CREATE VIEW` too.
public struct MSSQLModuleHeader: Sendable, Equatable {
    /// Where the whole name sits in the definition, in UTF-16 units, from its first part to its last.
    public let nameRange: NSRange

    /// The name's parts without their quotes, the schema first when the header names one.
    public let nameParts: [String]

    /// The header of `definition`, which must open with `CREATE [OR ALTER] <objectKeyword>` or
    /// `ALTER <objectKeyword>`, or nil when it does not or names its object with more than two parts.
    public static func parse(_ definition: String, objectKeyword: String) -> MSSQLModuleHeader? {
        var cursor = Cursor(text: definition as NSString)
        cursor.skipTrivia()
        if cursor.keyword("CREATE") {
            cursor.skipTrivia()
            if cursor.keyword("OR") {
                cursor.skipTrivia()
                guard cursor.keyword("ALTER") else { return nil }
                cursor.skipTrivia()
            }
        } else if cursor.keyword("ALTER") {
            cursor.skipTrivia()
        } else {
            return nil
        }
        guard cursor.keyword(objectKeyword) else { return nil }
        cursor.skipTrivia()

        let start = cursor.index
        var parts: [String] = []
        var end = start
        while true {
            guard let part = cursor.identifier() else { return nil }
            parts.append(part)
            end = cursor.index
            cursor.skipTrivia()
            guard cursor.consumePeriod() else { break }
            cursor.skipTrivia()
        }
        guard (1...2).contains(parts.count) else { return nil }
        return MSSQLModuleHeader(nameRange: NSRange(location: start, length: end - start), nameParts: parts)
    }

    /// `definition` with its header naming `[schema].[name]` when the name it declares is not the object's own.
    /// A header that already names the object, with or without its schema, is left exactly as it was written.
    public static func namingObject(
        in definition: String,
        objectKeyword: String,
        schema: String,
        name: String
    ) -> String {
        guard let header = parse(definition, objectKeyword: objectKeyword) else { return definition }
        let declaredSchema = header.nameParts.count == 2 ? header.nameParts.first : nil
        let isCurrent = header.nameParts.last == name && (declaredSchema == nil || declaredSchema == schema)
        guard !isCurrent else { return definition }
        let current = MSSQLSchemaQueries.bracketed(schema: schema, table: name)
        return (definition as NSString).replacingCharacters(in: header.nameRange, with: current)
    }
}

private struct Cursor {
    private static let period = UInt16(UnicodeScalar(".").value)
    private static let openBracket = UInt16(UnicodeScalar("[").value)
    private static let identifierSymbols: Set<UInt16> = Set("_@#$".utf16)

    let text: NSString
    let length: Int
    var index = 0

    init(text: NSString) {
        self.text = text
        self.length = text.length
    }

    mutating func skipTrivia() {
        while index < length {
            if SqlLexer.isWhitespace(text.character(at: index)) {
                index += 1
                continue
            }
            guard let span = SQLNonCodeSpan.span(at: index, in: text, grammar: SQLLexicalProfile.sqlServer),
                  span.kind.isComment
            else { return }
            index = max(span.end, index + 1)
        }
    }

    mutating func keyword(_ expected: String) -> Bool {
        let start = index
        guard let word = word(), word.caseInsensitiveCompare(expected) == .orderedSame else {
            index = start
            return false
        }
        return true
    }

    mutating func consumePeriod() -> Bool {
        guard index < length, text.character(at: index) == Self.period else { return false }
        index += 1
        return true
    }

    /// One part of a name: `[a]]b]`, `"a""b"` or a regular identifier.
    mutating func identifier() -> String? {
        guard index < length else { return nil }
        let opener = text.character(at: index)
        guard opener == Self.openBracket || opener == SqlLexer.doubleQuote else { return word() }
        guard let span = SQLNonCodeSpan.span(at: index, in: text, grammar: SQLLexicalProfile.sqlServer),
              span.kind == .quoted, span.isTerminated
        else { return nil }
        let body = text.substring(with: NSRange(location: span.start + 1, length: span.contentEnd - span.start - 1))
        index = span.end
        return opener == Self.openBracket
            ? body.replacingOccurrences(of: "]]", with: "]", options: .literal)
            : body.replacingOccurrences(of: "\"\"", with: "\"", options: .literal)
    }

    private mutating func word() -> String? {
        let start = index
        while index < length, isIdentifierUnit(text.character(at: index)) {
            index += 1
        }
        guard index > start else { return nil }
        return text.substring(with: NSRange(location: start, length: index - start))
    }

    private func isIdentifierUnit(_ unit: UInt16) -> Bool {
        SQLNonCodeSpan.isWordUnit(unit) || Self.identifierSymbols.contains(unit)
    }
}
