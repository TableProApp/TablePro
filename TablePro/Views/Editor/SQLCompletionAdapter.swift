//
//  SQLCompletionAdapter.swift
//  TablePro
//
//  Bridges CompletionEngine to the editor's completion system.
//  TODO: Adapt to TPCompletionController
//

import AppKit
import os
import SwiftUI

/// Adapts the existing CompletionEngine to the editor's suggestion system
/// TODO: Adapt to TPCompletionController — currently a standalone wrapper around CompletionEngine
@MainActor
final class SQLCompletionAdapter {
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

    // MARK: - Completion Queries

    // TODO: Adapt to TPCompletionController — these methods provide the core completion logic

    func completionTriggerCharacters() -> Set<String> {
        [".", " "]
    }

    /// Request completions at a given cursor offset in the provided text.
    func requestCompletions(
        text: String,
        cursorOffset: Int,
        isManualTrigger: Bool
    ) async -> CompletionContext? {
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

        // Don't show autocomplete right after semicolon or newline
        if cursorOffset > 0 {
            let nsString = text as NSString
            guard cursorOffset - 1 < nsString.length else { return nil }
            let prevChar = nsString.character(at: cursorOffset - 1)
            let semicolon = UInt16(UnicodeScalar(";").value)
            let newline = UInt16(UnicodeScalar("\n").value)

            if prevChar == semicolon || prevChar == newline {
                guard cursorOffset < nsString.length else { return nil }
                let afterCursor = nsString.substring(from: cursorOffset)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if afterCursor.isEmpty { return nil }
            }
        }

        await completionEngine.retrySchemaIfNeeded()

        guard let context = await completionEngine.getCompletions(
            text: text,
            cursorPosition: cursorOffset
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
        return context
    }

    /// Filter completions as the user types more characters.
    func filterCompletions(
        text: String,
        cursorOffset: Int
    ) -> [SQLCompletionItem]? {
        guard let context = currentCompletionContext,
              let provider = completionEngine?.provider else { return nil }

        let nsText = text as NSString
        let prefixStart = context.replacementRange.location
        guard cursorOffset >= prefixStart, cursorOffset <= nsText.length else { return nil }

        let currentPrefix = nsText.substring(
            with: NSRange(location: prefixStart, length: cursorOffset - prefixStart)
        ).lowercased()

        guard !currentPrefix.isEmpty else { return nil }

        let ranked = provider.filterAndRank(context.items, prefix: currentPrefix, context: context.sqlContext)
        return ranked.isEmpty ? nil : ranked
    }

    /// Mark that the next completion trigger should be suppressed (e.g., after applying a completion).
    func suppressNext() {
        suppressNextCompletion = true
    }
}
