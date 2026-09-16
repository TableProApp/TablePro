//
//  CompletionEngine.swift
//  TablePro
//
//  Stateless completion engine - pure logic, no UI
//

import Foundation
import TableProPluginKit

/// Completion context returned by the engine
struct CompletionContext {
    let items: [SQLCompletionItem]
    /// The wider ranked pool an open popup re-ranks against as the prefix grows. `items` is the
    /// slice of it the popup shows.
    let candidates: [SQLCompletionItem]
    let replacementRange: NSRange
    let sqlContext: SQLContext
}

/// Stateless completion engine that generates suggestions
final class CompletionEngine {
    // MARK: - Properties

    let provider: SQLCompletionProvider

    /// Size threshold (in UTF-16 code units) above which we extract a local
    /// window around the cursor instead of passing the full document to the
    /// context analyzer.  10 KB of UTF-16 ≈ 5 000 characters — more than
    /// enough for any single SQL statement the user is editing.
    private static let largeDocumentThreshold = 500_000
    private static let localWindowRadius = 5_000

    // MARK: - Initialization

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

    // MARK: - Public API

    /// Update favorite keywords for autocomplete expansion
    func updateFavoriteKeywords(_ keywords: [String: (name: String, query: String)]) {
        provider.updateFavoriteKeywords(keywords)
    }

    /// Statement-start keyword items available synchronously, without schema access.
    /// Used to seed a filterable completion context before the async fetch completes.
    func keywordCompletions() -> [SQLCompletionItem] {
        provider.statementStartCompletionItems()
    }

    /// All favorite keyword items, used to seed the pre-debounce completion
    /// session so favorites are filterable before the async fetch completes.
    func allFavoriteItems() -> [SQLCompletionItem] {
        provider.allFavoriteItems()
    }

    /// Filters, ranks and cases an open session's candidates for `prefix`.
    ///
    /// The engine is the single gate every SQL completion item passes through on its way to a UI
    /// surface, so the case policy is applied here rather than at each surface. `prefix` arrives in
    /// the case the user typed it; the matcher lowercases internally.
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

    /// Completions for a single-table filter expression (a bare WHERE-clause
    /// fragment such as `id = 1 AND na`). The fragment is completed as the WHERE
    /// clause it denotes and columns are scoped to `tableName`, so suggestions
    /// fire at every clause position. Returned ranges are relative to `fragment`.
    func filterCompletions(
        fragment: String,
        cursorPosition: Int,
        tableName: String,
        keywordCase: SQLKeywordCase = .default,
        trigger: SQLCompletionTrigger = .explicit
    ) async -> CompletionContext? {
        let clausePrefix = "WHERE "
        let prefixLength = (clausePrefix as NSString).length
        let analysisText = clausePrefix + fragment
        let references = [TableReference(tableName: tableName, alias: nil)]

        guard let context = await getCompletions(
            text: analysisText,
            cursorPosition: cursorPosition + prefixLength,
            keywordCase: keywordCase,
            trigger: trigger,
            forcedTableReferences: references
        ) else {
            return nil
        }

        let mappedLocation = context.replacementRange.location - prefixLength
        guard mappedLocation >= 0 else { return nil }
        let mappedRange = NSRange(location: mappedLocation, length: context.replacementRange.length)

        return CompletionContext(
            items: context.items,
            candidates: context.candidates,
            replacementRange: mappedRange,
            sqlContext: context.sqlContext
        )
    }

    /// Get completions for the given text and cursor position
    /// This is a pure function - no side effects
    func getCompletions(
        text: String,
        cursorPosition: Int,
        keywordCase: SQLKeywordCase = .default,
        trigger: SQLCompletionTrigger = .explicit,
        forcedTableReferences: [TableReference]? = nil
    ) async -> CompletionContext? {
        let nsText = text as NSString
        let textLength = nsText.length

        // For large documents, extract a local window around the cursor so the
        // context analyzer only processes ~10 KB instead of the full document.
        let analysisText: String
        let windowOffset: Int

        if textLength > Self.largeDocumentThreshold {
            let (window, offset) = extractLocalWindow(
                from: nsText, cursorPosition: cursorPosition
            )
            analysisText = window
            windowOffset = offset
        } else {
            analysisText = text
            windowOffset = 0
        }

        let adjustedCursor = cursorPosition - windowOffset

        let context = provider.analyzedContext(
            text: analysisText,
            cursorPosition: adjustedCursor,
            forcedTableReferences: forcedTableReferences
        )
        guard !SQLCompletionTriggerPolicy.suppressesEmptyPrefix(context, trigger: trigger) else {
            return nil
        }

        let (items, candidates) = await provider.completionSession(for: context)

        guard !items.isEmpty else {
            return nil
        }

        // Calculate replacement range — translate back to original document
        // positions by adding windowOffset
        let replaceStart = context.prefixRange.lowerBound + windowOffset
        let replaceEnd = context.prefixRange.upperBound + windowOffset
        let replacementRange = NSRange(
            location: replaceStart, length: replaceEnd - replaceStart
        )

        return CompletionContext(
            items: SQLCompletionCasing.applied(to: items, typedPrefix: context.prefix, policy: keywordCase),
            candidates: candidates,
            replacementRange: replacementRange,
            sqlContext: context.replacingPrefixRange(replaceStart..<replaceEnd)
        )
    }

    // MARK: - Local Window Extraction

    /// Extract a local window of text around the cursor for large documents.
    /// Finds the nearest statement boundaries (`;`) within the window so the
    /// analyzer gets a complete statement when possible.
    /// Uses NSString.substring(with:) for O(1) extraction.
    private func extractLocalWindow(
        from nsText: NSString,
        cursorPosition: Int
    ) -> (window: String, offset: Int) {
        let textLength = nsText.length
        let radius = Self.localWindowRadius

        var windowStart = max(0, cursorPosition - radius)
        let windowEnd = min(textLength, cursorPosition + radius)

        // Try to extend windowStart backwards to find a semicolon (statement
        // boundary) so the analyzer gets a complete statement
        if windowStart > 0 {
            let searchRange = NSRange(
                location: windowStart, length: cursorPosition - windowStart
            )
            let semiRange = nsText.range(
                of: ";",
                options: .backwards,
                range: searchRange
            )
            if semiRange.location != NSNotFound {
                // Start just after the semicolon
                windowStart = semiRange.location + 1
            }
        }

        let extractRange = NSRange(
            location: windowStart, length: windowEnd - windowStart
        )
        let window = nsText.substring(with: extractRange)
        return (window, windowStart)
    }
}
