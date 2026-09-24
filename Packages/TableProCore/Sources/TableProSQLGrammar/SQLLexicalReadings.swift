import Foundation

/// The lexical facts a driver learned from its own session, such as MySQL's `NO_BACKSLASH_ESCAPES` from the status
/// flags of the last reply.
public struct SQLSessionLexicalFacts: Sendable, Hashable {
    /// The facts the session settled.
    public let determined: SQLLexicalGrammar

    /// The settled facts that hold. Anything outside ``determined`` is ignored.
    public let enabled: SQLLexicalGrammar

    public init(determined: SQLLexicalGrammar, enabled: SQLLexicalGrammar) {
        self.determined = determined
        self.enabled = enabled.intersection(determined)
    }

    public func applied(to grammar: SQLLexicalGrammar) -> SQLLexicalGrammar {
        grammar.subtracting(determined).union(enabled)
    }
}

/// Every way an engine could lex a text, and the one it is split with for execution.
///
/// A gate never trusts a single reading where the engine could be using another: it classifies under every reading in
/// ``all`` and takes the worst, the highest statement count and the most severe tier. That covers a fact a server
/// decides per session and a driver did not report, a fact nobody measured, and an engine TablePro does not know at
/// all. Execution splits with ``execution`` alone, because a statement can only be sent one way.
///
/// A fact the session reported never narrows what a gate reads. It widens it when it disagrees with the curated
/// reading, and it chooses ``execution``. Narrowing would be wrong twice over: MySQL applies a `SET sql_mode` to the
/// rest of the same call, and its status flag after connect does not yet show a mode `init_connect` set, both
/// measured on 8.4 and 11.8.
public struct SQLLexicalReadings: Sendable, Hashable {
    public let execution: SQLLexicalGrammar

    /// Every plausible reading, ``execution`` first.
    public let all: [SQLLexicalGrammar]

    public init(execution: SQLLexicalGrammar, all: [SQLLexicalGrammar]) {
        self.execution = execution
        self.all = Self.deduplicated([execution] + all)
    }

    public static func single(_ grammar: SQLLexicalGrammar) -> SQLLexicalReadings {
        SQLLexicalReadings(execution: grammar, all: [grammar])
    }

    public var isAmbiguous: Bool {
        all.count > 1
    }

    /// Resolves the readings for a connection: the curated profile when TablePro knows the engine, which wins over
    /// anything a plugin declares because a registry plugin may be built against an older kit; otherwise what the
    /// plugin declared; otherwise every grammar TablePro knows, split for execution as standard SQL.
    public static func resolve(
        databaseTypeId: String,
        declared: SQLLexicalGrammar?,
        session: SQLSessionLexicalFacts?
    ) -> SQLLexicalReadings {
        let base = baseReadings(databaseTypeId: databaseTypeId, declared: declared)
        guard let session else { return base }
        let execution = session.applied(to: base.execution)
        return SQLLexicalReadings(execution: execution, all: base.all)
    }

    /// The readings that can lex `text` differently from each other, execution first.
    ///
    /// A fact no character in `text` can trigger is dropped from every reading before they are compared, so a query
    /// with no backslash is lexed once however many backslash rules are in doubt.
    public func distinct(for text: String) -> [SQLLexicalGrammar] {
        guard isAmbiguous else { return all }
        let relevant = SQLLexicalRelevance.facts(triggeredBy: text as NSString)
        return Self.deduplicated(all.map { $0.intersection(relevant) })
    }

    private static func baseReadings(databaseTypeId: String, declared: SQLLexicalGrammar?) -> SQLLexicalReadings {
        if let profile = SQLLexicalProfile.curated(forDatabaseTypeId: databaseTypeId) {
            return SQLLexicalReadings(execution: profile.grammar, all: profile.readings)
        }
        if let declared {
            return .single(declared)
        }
        return SQLLexicalReadings(execution: .ansi, all: SQLLexicalProfile.everyKnownReading)
    }

    private static func deduplicated(_ grammars: [SQLLexicalGrammar]) -> [SQLLexicalGrammar] {
        var seen: Set<SQLLexicalGrammar> = []
        return grammars.filter { seen.insert($0).inserted }
    }
}

/// Which lexical facts a text could possibly exercise, found in one pass over its UTF-16 units.
enum SQLLexicalRelevance {
    private static let openBracket = UInt16(UnicodeScalar("[").value)
    private static let at = UInt16(UnicodeScalar("@").value)
    private static let colon = UInt16(UnicodeScalar(":").value)
    private static let capitalG = UInt16(UnicodeScalar("G").value)
    private static let smallG = UInt16(UnicodeScalar("g").value)

    static func facts(triggeredBy text: NSString) -> SQLLexicalGrammar {
        let length = text.length
        var facts: SQLLexicalGrammar = [
            .plsqlBlocks, .delimiterDirective, .unterminatedStatements, .terminatedMergeStatements,
        ]
        var blockCommentOpeners = 0
        var index = 0
        while index < length {
            let unit = text.character(at: index)
            let next: UInt16 = index + 1 < length ? text.character(at: index + 1) : 0
            switch unit {
            case SqlLexer.backslash:
                facts.formUnion([
                    .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backslashEscapesInBackticks,
                    .escapeStringPrefix,
                ])
            case SqlLexer.backtick:
                facts.insert(.backtickQuotes)
            case openBracket:
                facts.formUnion([.bracketQuotedIdentifiers, .doubledClosingBracketEscapes])
            case SqlLexer.singleQuote, SqlLexer.doubleQuote:
                if next == unit, index + 2 < length, text.character(at: index + 2) == unit {
                    facts.insert(.tripleQuotedStrings)
                }
            case SqlDollarQuote.dollar:
                facts.formUnion([
                    .untaggedDollarQuotes, .taggedDollarQuotes, .dollarAndHashInIdentifiers,
                    .parenthesizedParameterNames,
                ])
            case SqlLexer.hash:
                facts.formUnion([.hashLineComments, .dollarAndHashInIdentifiers, .parenthesizedParameterNames])
            case at, colon:
                facts.insert(.parenthesizedParameterNames)
            case SqlLexer.slash:
                facts.insert(.slashLineTerminators)
                if next == SqlLexer.slash { facts.insert(.doubleSlashLineComments) }
                if next == SqlLexer.star {
                    blockCommentOpeners += 1
                    facts.insert(.executableComments)
                }
            case SqlLexer.dash where next == SqlLexer.dash:
                facts.insert(.dashCommentsNeedWhitespace)
            case SqlLexer.carriageReturn:
                facts.insert(.carriageReturnEndsLineComments)
            case SqlLexer.smallQ, SqlLexer.capitalQ:
                if next == SqlLexer.singleQuote { facts.insert(.alternativeQuoting) }
            case capitalG, smallG:
                facts.insert(.batchSeparatorLines)
            default:
                break
            }
            index += 1
        }
        if blockCommentOpeners > 1 {
            facts.insert(.nestedBlockComments)
        }
        return facts
    }
}
