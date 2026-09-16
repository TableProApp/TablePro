import Foundation
import TableProPluginKit

@MainActor
final class SQLCompletionService: QueryCompletionService {
    private let engine: CompletionEngine
    private var lastContext = SQLContext.unanalyzed

    private static let windowRadius = 5_000

    init(
        schemaProvider: SQLSchemaProvider?,
        databaseType: DatabaseType?,
        profile: QueryCompletionProfile? = nil
    ) {
        let dialect = profile?.resolvedDialect
            ?? databaseType.flatMap { PluginManager.shared.sqlDialect(for: $0) }
        let statementCompletions = profile?.statementCompletions
            ?? databaseType.flatMap { PluginManager.shared.statementCompletions(for: $0) }
            ?? []
        self.engine = CompletionEngine(
            schemaProvider: schemaProvider,
            databaseType: databaseType,
            dialect: dialect,
            statementCompletions: statementCompletions
        )
    }

    var triggerCharacters: Set<String> { [".", " ", ":", "(", ","] }

    /// Read per request rather than captured, so changing the setting applies to the next
    /// keystroke instead of the next connection.
    private var keywordCase: SQLKeywordCase { AppSettingsManager.shared.editor.keywordCase }

    /// Seeding starts a session the analyzer has not seen, so the context a previous session
    /// left behind stops describing anything. Ranking a seeded session against it would score
    /// the new prefix under the old clause.
    func seedItems() -> [SQLCompletionItem] {
        lastContext = .unanalyzed
        let items = engine.keywordCompletions() + engine.allFavoriteItems()
        return Array(items.prefix(engine.provider.seedPoolLimit))
    }

    func updateFavoriteKeywords(_ keywords: [String: (name: String, query: String)]) {
        engine.updateFavoriteKeywords(keywords)
    }

    func tokenStart(in text: NSString, endingAt offset: Int) -> Int {
        SQLTokenBoundary.segmentStart(in: text, endingAt: offset)
    }

    /// The incremental path reads its own prefix off the live token, which carries an opening
    /// identifier quote, so it takes the same match text the analyzer resolves for a fresh request.
    ///
    /// A token that is nothing but quotes declines instead of widening to every candidate: a
    /// re-rank cannot tell an identifier quote from the opening of a string, which `"` is on
    /// MySQL, and matching everything there would hold the popup open inside a string literal.
    /// Declining closes it, and the next character asks the analyzer, which reads the quote in
    /// its own context.
    func rank(_ items: [SQLCompletionItem], prefix: String) -> [SQLCompletionItem] {
        let matchText = SQLTokenBoundary.matchText(of: prefix)
        guard !matchText.isEmpty || prefix.isEmpty else { return [] }

        return engine.rank(
            items,
            prefix: matchText,
            context: lastContext,
            keywordCase: keywordCase
        )
    }

    func completions(in text: NSString, at offset: Int, isManualTrigger: Bool) async -> QueryCompletionSession? {
        guard !suppressesAfterStatementBreak(in: text, at: offset) else { return nil }

        let windowStart = max(0, offset - Self.windowRadius)
        let windowEnd = min(text.length, offset + Self.windowRadius)
        let window = text.substring(with: NSRange(location: windowStart, length: windowEnd - windowStart))

        guard let context = await engine.getCompletions(
            text: window,
            cursorPosition: offset - windowStart,
            keywordCase: keywordCase,
            trigger: isManualTrigger ? .explicit : .automatic
        ) else {
            return nil
        }

        lastContext = context.sqlContext
        return QueryCompletionSession(
            items: context.items,
            candidates: context.candidates,
            replacementRange: NSRange(
                location: context.replacementRange.location + windowStart,
                length: context.replacementRange.length
            )
        )
    }

    private func suppressesAfterStatementBreak(in text: NSString, at offset: Int) -> Bool {
        guard offset > 0, offset - 1 < text.length else { return false }

        let previous = text.character(at: offset - 1)
        let semicolon = UInt16(UnicodeScalar(";").value)
        let newline = UInt16(UnicodeScalar("\n").value)
        guard previous == semicolon || previous == newline else { return false }
        guard offset < text.length else { return true }

        return text.substring(from: offset).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
