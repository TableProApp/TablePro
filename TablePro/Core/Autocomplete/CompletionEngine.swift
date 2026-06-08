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
        schemaProvider: SQLSchemaProvider,
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

    func retrySchemaIfNeeded() async {
        await provider.retrySchemaIfNeeded()
    }

    /// Statement-start keyword items available synchronously, without schema access.
    /// Used to seed a filterable completion context before the async fetch completes.
    func keywordCompletions() -> [SQLCompletionItem] {
        provider.statementStartCompletionItems()
    }

    /// Completions for a single-table filter expression (a bare WHERE-clause
    /// fragment such as `id = 1 AND na`). The fragment is completed as the WHERE
    /// clause it denotes and columns are scoped to `tableName`, so suggestions
    /// fire at every clause position. Returned ranges are relative to `fragment`.
    func filterCompletions(
        fragment: String,
        cursorPosition: Int,
        tableName: String
    ) async -> CompletionContext? {
        let clausePrefix = "WHERE "
        let prefixLength = (clausePrefix as NSString).length
        let analysisText = clausePrefix + fragment
        let references = [TableReference(tableName: tableName, alias: nil)]

        guard let context = await getCompletions(
            text: analysisText,
            cursorPosition: cursorPosition + prefixLength,
            forcedTableReferences: references
        ) else {
            return nil
        }

        let mappedLocation = context.replacementRange.location - prefixLength
        guard mappedLocation >= 0 else { return nil }
        let mappedRange = NSRange(location: mappedLocation, length: context.replacementRange.length)

        return CompletionContext(
            items: context.items,
            replacementRange: mappedRange,
            sqlContext: context.sqlContext
        )
    }

    /// Get completions for the given text and cursor position
    /// This is a pure function - no side effects
    func getCompletions(
        text: String,
        cursorPosition: Int,
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

        // Get completions from provider (uses the potentially windowed text)
        let (items, context) = await provider.getCompletions(
            text: analysisText,
            cursorPosition: adjustedCursor,
            forcedTableReferences: forcedTableReferences
        )

        // Don't return empty results
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

        // Build a context with prefixRange adjusted back to original positions
        let adjustedContext = SQLContext(
            clauseType: context.clauseType,
            prefix: context.prefix,
            prefixRange: replaceStart..<replaceEnd,
            dotPrefix: context.dotPrefix,
            tableReferences: context.tableReferences,
            isInsideString: context.isInsideString,
            isInsideComment: context.isInsideComment,
            cteNames: context.cteNames,
            nestingLevel: context.nestingLevel,
            currentFunction: context.currentFunction,
            isAfterComma: context.isAfterComma
        )

        return CompletionContext(
            items: items,
            replacementRange: replacementRange,
            sqlContext: adjustedContext
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

        // Raw window bounds
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
