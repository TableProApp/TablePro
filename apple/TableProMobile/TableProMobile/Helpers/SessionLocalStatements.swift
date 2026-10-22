import Foundation
import TableProModels
import TableProSQLGrammar

// What a run leaves on its own session that a catalog connection beside it never sees. Read from every statement the
// run planned, sent or not, so it only ever sends more reads to the session, which always answers right.
nonisolated enum SessionLocalStatements {
    nonisolated struct Effect: Equatable {
        // Kept after a DROP too: a failed script may never have reached it, and the session answers either way.
        var temporaryTables: Set<String> = []
        // A `USE`, a role or a search path moved the session off what the catalog connection sees, or a procedure or
        // dynamic SQL may have made a table only the session sees.
        var leavesCatalog = false
    }

    private static let identifier = #"(`(?:[^`]|``)+`|"(?:[^"]|"")+"|\[[^\]]+\]|[\w$#]+)"#
    private static let qualified = #"(?:"# + identifier + #"\s*\.\s*)?"# + identifier

    private static let createPattern = try? NSRegularExpression(
        pattern: #"^\s*CREATE\s+(?:OR\s+REPLACE\s+)?(?:GLOBAL\s+|LOCAL\s+)?TEMP(?:ORARY)?\s+TABLE(?:\s+IF\s+NOT\s+EXISTS)?(?=\s)"#,
        options: [.caseInsensitive]
    )

    // Anywhere in the code, as a SQL Server batch needs no `;` before it; MySQL's `USE INDEX` hint is not one. The
    // projection blanks a quoted name, so nothing after `USE` is required.
    private static let usePattern = try? NSRegularExpression(
        pattern: #"\bUSE\b(?!\s+(?:INDEX|KEY)\b)"#,
        options: [.caseInsensitive]
    )

    // Who the session is and where it looks up a bare name: a role or a search path the catalog connection never set.
    private static let contextPattern = try? NSRegularExpression(
        pattern: #"^\s*(?:(?:SET|RESET)\s+(?:SESSION\s+|LOCAL\s+)?(?:ROLE|SESSION\s+AUTHORIZATION|SEARCH_PATH|SCHEMA|ALL)\b"#
            + #"|ALTER\s+SESSION\s+SET\s+CURRENT_SCHEMA\b|DISCARD\s+ALL\b)"#,
        options: [.caseInsensitive]
    )

    private static let namePattern = try? NSRegularExpression(pattern: "^" + qualified)

    private static let databaseChangePattern = try? NSRegularExpression(
        pattern: #"\b(?:DROP|ALTER|RESTORE)\s+DATABASE\b"#,
        options: [.caseInsensitive]
    )

    // SQL Server cannot drop, restore or take single-user a database the catalog connection sits in. Read on the raw
    // text, since `EXEC(N'DROP DATABASE ...')` hides it in a string; a procedure there may do it unseen.
    static func changesDatabases(_ text: String, databaseType: DatabaseType) -> Bool {
        let range = NSRange(location: 0, length: (text as NSString).length)
        if databaseChangePattern?.firstMatch(in: text, range: range) != nil { return true }
        guard databaseType == .mssql else { return false }
        let grammar = SQLLexicalReadings.resolve(
            databaseTypeId: databaseType.rawValue, declared: nil, session: nil
        ).execution
        return SQLCatalogEffectClassifier.effect(of: text, grammar: grammar).runsUnseenStatements
    }

    static func effect(of statements: [String], databaseType: DatabaseType) -> Effect {
        let grammar = SQLLexicalReadings.resolve(
            databaseTypeId: databaseType.rawValue, declared: nil, session: nil
        ).execution
        var effect = Effect()
        for statement in statements {
            // Read on the code alone, with its quoted names kept, so a comment or a string never names a table.
            let code = SQLCodeProjection.code(of: statement, grammar: grammar, revealingExecutableComments: true)
            if let name = tableName(matching: createPattern, in: code, source: statement as NSString, grammar: grammar) {
                effect.temporaryTables.insert(name)
            }
            let range = NSRange(location: 0, length: (code as NSString).length)
            // A MySQL executable comment can hide any statement, a temporary table among them, from the patterns.
            if usePattern?.firstMatch(in: code, range: range) != nil
                || contextPattern?.firstMatch(in: code, range: range) != nil
                || SQLLeadingComments.conditionalCommentOpeners.contains(where: {
                    (code as NSString).range(of: $0, options: .literal).location != NSNotFound
                })
                || SQLCatalogEffectClassifier.effect(of: statement, grammar: grammar).runsUnseenStatements {
                effect.leavesCatalog = true
            }
        }
        return effect
    }

    // The keywords are matched on the code, where quoted names are blanked; the name is read from the source after
    // them, past any blank or comment.
    private static func tableName(
        matching pattern: NSRegularExpression?,
        in code: String,
        source: NSString,
        grammar: SQLLexicalGrammar
    ) -> String? {
        let range = NSRange(location: 0, length: (code as NSString).length)
        guard let pattern, let namePattern, let match = pattern.firstMatch(in: code, range: range),
              NSMaxRange(match.range) <= source.length else { return nil }
        let start = nameStart(after: NSMaxRange(match.range), in: source, grammar: grammar)
        let tail = source.substring(from: start)
        let tailRange = NSRange(location: 0, length: (tail as NSString).length)
        guard let name = namePattern.firstMatch(in: tail, range: tailRange) else { return nil }
        let nameRange = name.range(at: name.numberOfRanges - 1)
        guard nameRange.location != NSNotFound else { return nil }
        return unquoted((tail as NSString).substring(with: nameRange)).lowercased()
    }

    private static func nameStart(after offset: Int, in source: NSString, grammar: SQLLexicalGrammar) -> Int {
        var index = offset
        while index < source.length {
            if let span = SQLNonCodeSpan.span(at: index, in: source, grammar: grammar), span.kind.isComment {
                index = max(span.end, index + 1)
                continue
            }
            let blank = StatementBlank.blankLength(in: source, at: index)
            guard blank > 0 else { return index }
            index += blank
        }
        return index
    }

    private static func unquoted(_ name: String) -> String {
        guard let first = name.first, let last = name.last, name.count >= 2 else { return name }
        switch (first, last) {
        case ("`", "`"): return String(name.dropFirst().dropLast()).replacingOccurrences(of: "``", with: "`")
        case ("\"", "\""): return String(name.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
        case ("[", "]"): return String(name.dropFirst().dropLast())
        default: return name
        }
    }
}
