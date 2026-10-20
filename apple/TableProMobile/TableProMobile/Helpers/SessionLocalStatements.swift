import Foundation
import TableProModels
import TableProSQLGrammar

// What a run leaves on its own session that a catalog connection beside it never sees. Read from every statement the
// run planned, sent or not, so it only ever sends more reads to the session, which always answers right.
nonisolated enum SessionLocalStatements {
    nonisolated struct Effect: Equatable {
        // Kept after a DROP too: a failed script may never have reached it, and the session answers either way.
        var temporaryTables: Set<String> = []
        // A `USE` moved the session off the database the catalog connection opens, or a procedure, dynamic SQL or an
        // ATTACH may have made a table only the session sees.
        var leavesCatalog = false
    }

    private static let identifier = #"(`(?:[^`]|``)+`|"(?:[^"]|"")+"|\[[^\]]+\]|[\w$#]+)"#
    private static let qualified = #"(?:"# + identifier + #"\s*\.\s*)?"# + identifier

    private static let createPattern = try? NSRegularExpression(
        pattern: #"^\s*CREATE\s+(?:GLOBAL\s+|LOCAL\s+)?TEMP(?:ORARY)?\s+TABLE(?:\s+IF\s+NOT\s+EXISTS)?(?=\s)"#,
        options: [.caseInsensitive]
    )

    // Anywhere in the code, as a SQL Server batch needs no `;` before it; MySQL's `USE INDEX` hint is not one. The
    // projection blanks a quoted name, so nothing after `USE` is required.
    private static let usePattern = try? NSRegularExpression(
        pattern: #"\bUSE\b(?!\s+(?:INDEX|KEY)\b)"#,
        options: [.caseInsensitive]
    )

    // The keyword match stops before the blank the projection put where a quoted name was.
    private static let namePattern = try? NSRegularExpression(pattern: #"^\s+"# + qualified)

    static func effect(of statements: [String], databaseType: DatabaseType) -> Effect {
        let grammar = SQLLexicalReadings.resolve(
            databaseTypeId: databaseType.rawValue, declared: nil, session: nil
        ).execution
        var effect = Effect()
        for statement in statements {
            // Read on the code alone, with its quoted names kept, so a comment or a string never names a table.
            let code = SQLCodeProjection.code(of: statement, grammar: grammar, revealingExecutableComments: true)
            if let name = tableName(matching: createPattern, in: code, source: statement as NSString) {
                effect.temporaryTables.insert(name)
            }
            let range = NSRange(location: 0, length: (code as NSString).length)
            if usePattern?.firstMatch(in: code, range: range) != nil
                || SQLCatalogEffectClassifier.effect(of: statement, grammar: grammar) == .opaque {
                effect.leavesCatalog = true
            }
        }
        return effect
    }

    // The keywords are matched on the code, where quoted names are blanked; the name is read from the source after them.
    private static func tableName(matching pattern: NSRegularExpression?, in code: String, source: NSString) -> String? {
        let range = NSRange(location: 0, length: (code as NSString).length)
        guard let pattern, let namePattern, let match = pattern.firstMatch(in: code, range: range),
              NSMaxRange(match.range) <= source.length else { return nil }
        let tail = source.substring(from: NSMaxRange(match.range))
        let tailRange = NSRange(location: 0, length: (tail as NSString).length)
        guard let name = namePattern.firstMatch(in: tail, range: tailRange) else { return nil }
        let nameRange = name.range(at: name.numberOfRanges - 1)
        guard nameRange.location != NSNotFound else { return nil }
        return unquoted((tail as NSString).substring(with: nameRange)).lowercased()
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
