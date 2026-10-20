import Foundation
import TableProModels
import TableProSQLGrammar

// The temporary tables a run created or dropped: they live only on its session, which a catalog connection never sees.
nonisolated enum TemporaryTableStatements {
    nonisolated struct Change: Equatable {
        var created: Set<String> = []
        var dropped: Set<String> = []
    }

    private static let identifier = #"(`(?:[^`]|``)+`|"(?:[^"]|"")+"|\[[^\]]+\]|[\w$#]+)"#
    private static let qualified = #"(?:"# + identifier + #"\s*\.\s*)?"# + identifier

    private static let createPattern = try? NSRegularExpression(
        pattern: #"^\s*CREATE\s+(?:GLOBAL\s+|LOCAL\s+)?TEMP(?:ORARY)?\s+TABLE(?:\s+IF\s+NOT\s+EXISTS)?(?=\s)"#,
        options: [.caseInsensitive]
    )

    private static let dropPattern = try? NSRegularExpression(
        pattern: #"^\s*DROP\s+(?:TEMPORARY\s+)?TABLE(?:\s+IF\s+EXISTS)?(?=\s)"#,
        options: [.caseInsensitive]
    )

    // The keyword match stops before the blank the projection put where a quoted name was.
    private static let namePattern = try? NSRegularExpression(pattern: #"^\s+"# + qualified)

    static func change(in statements: [String], databaseType: DatabaseType) -> Change {
        let grammar = SQLLexicalReadings.resolve(
            databaseTypeId: databaseType.rawValue, declared: nil, session: nil
        ).execution
        var change = Change()
        for statement in statements {
            // Read on the code alone, with its quoted names kept, so a comment or a string never names a table.
            let code = SQLCodeProjection.code(of: statement, grammar: grammar, revealingExecutableComments: true)
            let source = statement as NSString
            if let name = tableName(matching: createPattern, in: code, source: source) {
                change.created.insert(name)
                change.dropped.remove(name)
            } else if let name = tableName(matching: dropPattern, in: code, source: source) {
                change.dropped.insert(name)
                change.created.remove(name)
            }
        }
        return change
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
