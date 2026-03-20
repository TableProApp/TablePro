//
//  SQLCompletionAdapter.swift
//  TablePro
//
//  Bridges CompletionEngine to CodeEditSourceEditor's CodeSuggestionDelegate.
//

import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import os
import SwiftUI

/// Adapts the existing CompletionEngine to CodeEditSourceEditor's suggestion system
@MainActor
final class SQLCompletionAdapter: CodeSuggestionDelegate {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLCompletionAdapter")

    // MARK: - Properties

    private var completionEngine: CompletionEngine?
    private var favoriteKeywords: [String: (name: String, query: String)] = [:]
    private var suppressNextCompletion = false
    private var currentCompletionContext: CompletionContext?
    private var debounceGeneration: UInt64 = 0
    private let debounceNanoseconds: UInt64 = 50_000_000  // 50ms

    // MARK: - Initialization

    init(schemaProvider: SQLSchemaProvider?, databaseType: DatabaseType? = nil) {
        if let provider = schemaProvider {
            let dialect = databaseType.flatMap { PluginManager.shared.sqlDialect(for: $0) }
            let completions = databaseType.flatMap { PluginManager.shared.statementCompletions(for: $0) } ?? []
            self.completionEngine = CompletionEngine(
                schemaProvider: provider, databaseType: databaseType,
                dialect: dialect, statementCompletions: completions
            )
        }
    }

    /// Update the schema provider (e.g. when connection changes)
    func updateSchemaProvider(_ provider: SQLSchemaProvider, databaseType: DatabaseType? = nil) {
        let dialect = databaseType.flatMap { PluginManager.shared.sqlDialect(for: $0) }
        let completions = databaseType.flatMap { PluginManager.shared.statementCompletions(for: $0) } ?? []
        self.completionEngine = CompletionEngine(
            schemaProvider: provider, databaseType: databaseType,
            dialect: dialect, statementCompletions: completions
        )
        completionEngine?.updateFavoriteKeywords(favoriteKeywords)
    }

    /// Update favorite keywords for autocomplete expansion
    func updateFavoriteKeywords(_ keywords: [String: (name: String, query: String)]) {
        favoriteKeywords = keywords
        completionEngine?.updateFavoriteKeywords(keywords)
    }

    // MARK: - CodeSuggestionDelegate

    func completionTriggerCharacters() -> Set<String> {
        [".", " "]
    }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition,
        isManualTrigger: Bool
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        guard let completionEngine else {
            Self.logger.debug("Completion skipped: no engine (schema provider was nil at init)")
            return nil
        }

        if suppressNextCompletion {
            suppressNextCompletion = false
            return nil
        }

        // Debounce: wait briefly and check if a newer request arrived
        debounceGeneration &+= 1
        let myGeneration = debounceGeneration
        try? await Task.sleep(nanoseconds: debounceNanoseconds)
        guard myGeneration == debounceGeneration else { return nil }

        let text = textView.text
        let offset = cursorPosition.range.location

        // Don't show autocomplete right after semicolon or newline
        if offset > 0 {
            let nsString = text as NSString
            guard offset - 1 < nsString.length else { return nil }
            let prevChar = nsString.character(at: offset - 1)
            let semicolon = UInt16(UnicodeScalar(";").value)
            let newline = UInt16(UnicodeScalar("\n").value)

            if prevChar == semicolon || prevChar == newline {
                guard offset < nsString.length else { return nil }
                let afterCursor = nsString.substring(from: offset)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if afterCursor.isEmpty { return nil }
            }
        }

        await completionEngine.retrySchemaIfNeeded()

        guard let context = await completionEngine.getCompletions(
            text: text,
            cursorPosition: offset
        ) else {
            return nil
        }

        // Suppress noisy completions when prefix is empty in contexts where
        // browsing all items isn't useful (e.g., after "SELECT " or "WHERE ").
        // Manual triggers (Ctrl+Space) always show completions.
        if !isManualTrigger && context.sqlContext.prefix.isEmpty && context.sqlContext.dotPrefix == nil {
            switch context.sqlContext.clauseType {
            case .from, .join, .into, .set, .insertColumns, .on,
                 .alterTableColumn, .returning, .using, .dropObject, .createIndex:
                break // Allow empty-prefix completions for these browseable contexts
            default:
                return nil
            }
        }

        self.currentCompletionContext = context

        let entries: [CodeSuggestionEntry] = context.items.map { item in
            SQLSuggestionEntry(item: item)
        }

        return (windowPosition: cursorPosition, items: entries)
    }

    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        guard let context = currentCompletionContext,
              let provider = completionEngine?.provider else { return nil }

        let text = textView.text
        let offset = cursorPosition.range.location
        let nsText = text as NSString

        let prefixStart = context.replacementRange.location
        guard offset >= prefixStart, offset <= nsText.length else { return nil }

        let currentPrefix = nsText.substring(
            with: NSRange(location: prefixStart, length: offset - prefixStart)
        ).lowercased()

        guard !currentPrefix.isEmpty else { return nil }

        let ranked = provider.filterAndRank(context.items, prefix: currentPrefix, context: context.sqlContext)

        return ranked.isEmpty ? nil : ranked.map { SQLSuggestionEntry(item: $0) }
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {
        guard let entry = item as? SQLSuggestionEntry,
              let context = currentCompletionContext else { return }

        suppressNextCompletion = true

        // Extend replacement range from original start to current cursor position,
        // since the user may have typed more characters since completions were triggered.
        let originalStart = context.replacementRange.location
        let currentEnd = cursorPosition?.range.location ?? (originalStart + context.replacementRange.length)
        let replaceRange = NSRange(location: originalStart, length: currentEnd - originalStart)
        let insertText = entry.item.insertText

        // Replace text in the text view
        textView.textView.replaceCharacters(
            in: [replaceRange],
            with: insertText
        )

        // Move cursor: for function completions ending with "()", place cursor between parens
        let insertLength = (insertText as NSString).length
        let newPosition: Int
        if insertText.hasSuffix("()") {
            newPosition = replaceRange.location + insertLength - 1
        } else {
            newPosition = replaceRange.location + insertLength
        }
        textView.setCursorPositions([CursorPosition(range: NSRange(location: newPosition, length: 0))])
    }
}

// MARK: - SQLSuggestionEntry

/// Bridges SQLCompletionItem to CodeSuggestionEntry
final class SQLSuggestionEntry: CodeSuggestionEntry {
    let item: SQLCompletionItem

    init(item: SQLCompletionItem) {
        self.item = item
    }

    var label: String { item.label }
    var detail: String? { item.detail }
    var documentation: String? { item.documentation }
    var pathComponents: [String]? { nil }
    var targetPosition: CursorPosition? { nil }
    var sourcePreview: String? { nil }
    var deprecated: Bool { false }
    var matchedRanges: [Range<Int>] { item.matchedRanges }

    var image: Image {
        Image(systemName: item.kind.iconName)
    }

    var imageColor: Color {
        Color(nsColor: item.kind.iconColor)
    }
}
