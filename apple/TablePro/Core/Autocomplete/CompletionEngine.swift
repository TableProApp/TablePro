import Foundation
import TableProAutocomplete
import TableProPluginKit

struct CompletionContext {
    let items: [SQLCompletionItem]
    // The wider ranked pool an open popup re-ranks against as the prefix grows; `items` is the slice it shows.
    let candidates: [SQLCompletionItem]
    let replacementRange: NSRange
    let sqlContext: SQLContext
}

final class CompletionEngine {
    private let provider: SQLCompletionProvider

    init(
        schemaProvider: SQLSchemaProvider?,
        databaseType: DatabaseType? = nil,
        dialect: SQLDialectDescriptor? = nil,
        statementCompletions: [CompletionEntry] = []
    ) {
        self.provider = SQLCompletionProvider(
            schemaProvider: schemaProvider,
            databaseType: databaseType,
            dialect: dialect,
            statementCompletions: statementCompletions
        )
    }

    func updateFavoriteKeywords(_ keywords: [String: (name: String, query: String)]) {
        provider.updateFavoriteKeywords(keywords)
    }

    // Every SQL completion reaches a UI surface through here, so the case policy is applied once.
    func rank(
        _ items: [SQLCompletionItem],
        prefix: String,
        context: SQLContext,
        keywordCase: SQLKeywordCase
    ) -> [SQLCompletionItem] {
        SQLCompletionCasing.applied(
            to: provider.filterRankAndLimit(items, prefix: prefix, context: context),
            typedPrefix: prefix,
            policy: keywordCase
        )
    }

    // A bare filter fragment completes as the WHERE clause it denotes; ranges come back relative to `fragment`.
    func filterCompletions(
        fragment: String,
        cursorPosition: Int,
        tableName: String,
        keywordCase: SQLKeywordCase = .default
    ) async -> CompletionContext? {
        let clausePrefix = "WHERE "
        let prefixLength = (clausePrefix as NSString).length
        let references = [TableReference(tableName: tableName, alias: nil)]

        guard let context = await getCompletions(
            text: clausePrefix + fragment,
            cursorPosition: cursorPosition + prefixLength,
            keywordCase: keywordCase,
            forcedTableReferences: references
        ), context.replacementRange.location >= prefixLength else {
            return nil
        }

        let sqlContext = context.sqlContext.offset(by: -prefixLength)
        return CompletionContext(
            items: context.items,
            candidates: context.candidates,
            replacementRange: NSRange(sqlContext.prefixRange),
            sqlContext: sqlContext
        )
    }

    // Ranges are relative to `text`; a caller that hands in a window shifts the context back with `offset(by:)`.
    func getCompletions(
        text: String,
        cursorPosition: Int,
        keywordCase: SQLKeywordCase = .default,
        forcedTableReferences: [TableReference]? = nil
    ) async -> CompletionContext? {
        let (items, candidates, context) = await provider.completionSession(
            text: text,
            cursorPosition: cursorPosition,
            forcedTableReferences: forcedTableReferences
        )
        guard !items.isEmpty else { return nil }

        return CompletionContext(
            items: SQLCompletionCasing.applied(to: items, typedPrefix: context.prefix, policy: keywordCase),
            candidates: candidates,
            replacementRange: NSRange(context.prefixRange),
            sqlContext: context
        )
    }
}
