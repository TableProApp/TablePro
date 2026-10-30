import Foundation
import TableProAutocomplete
import TableProPluginKit
import TableProSQLGrammar

struct CompletionContext {
    let items: [SQLCompletionItem]
    // The wider ranked pool an open popup re-ranks against as the prefix grows; `items` is the slice it shows.
    let candidates: [SQLCompletionItem]
    let candidatesTruncated: Bool
    let replacementRange: NSRange
    let sqlContext: SQLContext
}

final class CompletionEngine {
    private let provider: SQLCompletionProvider
    private let identifierRules: SQLIdentifierRules?

    init(
        schemaProvider: SQLSchemaProvider?,
        databaseType: DatabaseType? = nil,
        dialect: SQLDialectDescriptor? = nil,
        statementCompletions: [CompletionEntry] = [],
        grammar: SQLLexicalGrammar? = nil
    ) {
        self.provider = SQLCompletionProvider(
            schemaProvider: schemaProvider,
            databaseType: databaseType,
            dialect: dialect,
            statementCompletions: statementCompletions,
            grammar: grammar
        )
        self.identifierRules = databaseType?.identifierRules
    }

    func updateFavoriteKeywords(_ keywords: [String: (name: String, query: String)]) {
        provider.updateFavoriteKeywords(keywords)
    }

    // Every SQL completion item passes through the engine on its way to a surface, so both case policies apply here.
    func rank(
        _ items: [SQLCompletionItem],
        prefix: String,
        context: SQLContext,
        keywordCase: SQLKeywordCase,
        identifierCase: SQLIdentifierCase = .default
    ) -> [SQLCompletionItem] {
        spelled(
            provider.filterRankAndLimit(items, prefix: prefix, context: context),
            typedPrefix: prefix,
            context: context,
            keywordCase: keywordCase,
            identifierCase: identifierCase
        )
    }

    private func spelled(
        _ items: [SQLCompletionItem],
        typedPrefix: String,
        context: SQLContext,
        keywordCase: SQLKeywordCase,
        identifierCase: SQLIdentifierCase
    ) -> [SQLCompletionItem] {
        let cased = SQLCompletionCasing.applied(to: items, typedPrefix: typedPrefix, policy: keywordCase)
        guard let identifierRules else { return cased }
        return SQLIdentifierSpelling(rules: identifierRules, policy: identifierCase).applied(
            to: cased,
            typedPrefix: typedPrefix,
            quoting: SQLIdentifierTokenQuoting(context.quotedName)
        )
    }

    // A bare filter fragment completes as the WHERE clause it denotes; ranges come back relative to `fragment`.
    func filterCompletions(
        fragment: String,
        cursorPosition: Int,
        tableName: String,
        keywordCase: SQLKeywordCase = .default,
        identifierCase: SQLIdentifierCase = .default
    ) async -> CompletionContext? {
        let clausePrefix = "WHERE "
        let prefixLength = (clausePrefix as NSString).length
        let references = [TableReference(tableName: tableName, alias: nil)]

        guard let context = await getCompletions(
            text: clausePrefix + fragment,
            cursorPosition: cursorPosition + prefixLength,
            keywordCase: keywordCase,
            identifierCase: identifierCase,
            forcedTableReferences: references
        ), context.replacementRange.location >= prefixLength else {
            return nil
        }

        let sqlContext = context.sqlContext.offset(by: -prefixLength)
        return CompletionContext(
            items: context.items,
            candidates: context.candidates,
            candidatesTruncated: context.candidatesTruncated,
            replacementRange: NSRange(sqlContext.prefixRange),
            sqlContext: sqlContext
        )
    }

    // Ranges are relative to `text`; a caller that hands in a window shifts the context back with `offset(by:)`.
    func getCompletions(
        text: String,
        cursorPosition: Int,
        keywordCase: SQLKeywordCase = .default,
        identifierCase: SQLIdentifierCase = .default,
        forcedTableReferences: [TableReference]? = nil
    ) async -> CompletionContext? {
        let session = await provider.completionSession(
            text: text,
            cursorPosition: cursorPosition,
            forcedTableReferences: forcedTableReferences
        )
        guard !session.items.isEmpty else { return nil }

        return CompletionContext(
            items: spelled(
                session.items,
                typedPrefix: session.context.prefix,
                context: session.context,
                keywordCase: keywordCase,
                identifierCase: identifierCase
            ),
            candidates: session.candidates,
            candidatesTruncated: session.candidatesTruncated,
            replacementRange: NSRange(session.context.prefixRange),
            sqlContext: session.context
        )
    }
}
