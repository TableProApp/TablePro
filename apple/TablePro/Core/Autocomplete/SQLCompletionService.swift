import Foundation
import TableProAutocomplete
import TableProPluginKit
import TableProSQLGrammar

@MainActor
final class SQLCompletionService: QueryCompletionService {
    private let engine: CompletionEngine
    private let grammar: SQLLexicalGrammar
    private let identifierCaseSource: @MainActor () -> SQLIdentifierCase
    private var lastContext = SQLContext.unanalyzed

    init(
        schemaProvider: SQLSchemaProvider?,
        databaseType: DatabaseType?,
        profile: QueryCompletionProfile? = nil,
        grammar: SQLLexicalGrammar? = nil,
        identifierCase: @escaping @MainActor () -> SQLIdentifierCase = { .default }
    ) {
        let dialect = profile?.resolvedDialect
            ?? databaseType.flatMap { PluginManager.shared.sqlDialect(for: $0) }
        let statementCompletions = profile?.statementCompletions
            ?? databaseType.flatMap { PluginManager.shared.statementCompletions(for: $0) }
            ?? []
        let resolvedGrammar = grammar ?? databaseType?.lexicalGrammar ?? .ansi
        self.engine = CompletionEngine(
            schemaProvider: schemaProvider,
            databaseType: databaseType,
            dialect: dialect,
            statementCompletions: statementCompletions,
            grammar: resolvedGrammar
        )
        self.grammar = resolvedGrammar
        self.identifierCaseSource = identifierCase
    }

    var triggerCharacters: Set<String> { [".", " ", ":", "(", ","] }

    // Read per request, so a changed setting applies to the next keystroke rather than the next connection.
    private var keywordCase: SQLKeywordCase { AppSettingsManager.shared.editor.keywordCase }
    private var identifierCase: SQLIdentifierCase { identifierCaseSource() }

    func updateFavoriteKeywords(_ keywords: [String: (name: String, query: String)]) {
        engine.updateFavoriteKeywords(keywords)
    }

    func tokenStart(in text: NSString, endingAt offset: Int) -> Int {
        SQLTokenBoundary.segmentStart(in: text, endingAt: offset, grammar: grammar)
    }

    // A quotes-only token declines instead of matching everything: a re-rank cannot tell an identifier quote from a
    // MySQL string's `"`, and the next character asks the analyzer, which can.
    func rank(_ items: [SQLCompletionItem], prefix: String) -> [SQLCompletionItem] {
        let matchText = SQLTokenBoundary.matchText(of: prefix)
        guard !matchText.isEmpty || prefix.isEmpty else { return [] }

        return engine.rank(
            items,
            prefix: matchText,
            context: lastContext,
            keywordCase: keywordCase,
            identifierCase: identifierCase
        )
    }

    func completions(in text: NSString, at offset: Int, isManualTrigger: Bool) async -> QueryCompletionSession? {
        guard !SQLCompletionTriggerPolicy.suppressesAfterStatementBreak(in: text, at: offset),
              let window = await SQLCompletionWindow.cut(text as String, around: offset, grammar: grammar),
              let result = await engine.getCompletions(
                  text: window.text,
                  cursorPosition: offset - window.start,
                  keywordCase: keywordCase,
                  identifierCase: identifierCase
              ) else {
            return nil
        }

        let context = result.sqlContext.offset(by: window.start)
        guard !SQLCompletionTriggerPolicy.suppressesEmptyPrefix(context, isManualTrigger: isManualTrigger) else {
            return nil
        }

        lastContext = context
        return QueryCompletionSession(
            items: result.items,
            candidates: result.candidates,
            replacementRange: NSRange(context.prefixRange),
            quotedName: context.quotedName,
            candidatesTruncated: result.candidatesTruncated
        )
    }
}
