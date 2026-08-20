//
//  QueryCompletionAdapter.swift
//  TablePro
//
//  Bridges a per-language QueryCompletionService to CodeEditSourceEditor's
//  CodeSuggestionDelegate.
//

import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import os
import SwiftUI

@MainActor
final class QueryCompletionAdapter: CodeSuggestionDelegate {
    private struct Session {
        var items: [SQLCompletionItem]
        var replacementRange: NSRange
    }

    private var service: QueryCompletionService
    private var favoriteKeywords: [String: (name: String, query: String)] = [:]
    private var session: Session?

    private let debounceNanoseconds: UInt64 = 50_000_000
    private let refilterDebounceNanoseconds: UInt64 = 30_000_000
    private let maximumPrefixLength = 500

    private var cursorRefilterTask: Task<Void, Never>?
    private var lastRefilterPrefix: String?
    private var lastRefilterItems: [SQLCompletionItem]?

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "QueryCompletionAdapter")

    init(schemaProvider: SQLSchemaProvider?, databaseType: DatabaseType? = nil) {
        self.service = QueryCompletionServiceFactory.make(schemaProvider: schemaProvider, databaseType: databaseType)
    }

    func configure(schemaProvider: SQLSchemaProvider?, databaseType: DatabaseType?) {
        service = QueryCompletionServiceFactory.make(schemaProvider: schemaProvider, databaseType: databaseType)
        service.updateFavoriteKeywords(favoriteKeywords)
        session = nil
        clearRefilterState()
    }

    func updateFavoriteKeywords(_ keywords: [String: (name: String, query: String)]) {
        favoriteKeywords = keywords
        service.updateFavoriteKeywords(keywords)
    }

    // MARK: - CodeSuggestionDelegate

    func completionTriggerCharacters() -> Set<String> {
        service.triggerCharacters
    }

    func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition,
        isManualTrigger: Bool
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        guard !textView.textView.hasMarkedText() else { return nil }

        seedSessionIfNeeded(textView: textView, cursorPosition: cursorPosition)

        do {
            try await Task.sleep(nanoseconds: debounceNanoseconds)
        } catch {
            return nil
        }

        guard !textView.textView.hasMarkedText() else { return nil }

        let liveCursorPosition = textView.cursorPositions.first ?? cursorPosition
        let text = (textView.textView.textStorage?.string ?? "") as NSString
        let offset = liveCursorPosition.range.location
        guard offset >= 0, offset <= text.length else { return nil }

        await service.prepare()

        guard let result = await service.completions(
            in: text,
            at: offset,
            isManualTrigger: isManualTrigger
        ), !Task.isCancelled else {
            return nil
        }

        clearRefilterState()
        session = Session(items: result.items, replacementRange: result.replacementRange)

        return (windowPosition: liveCursorPosition, items: result.items.map { SQLSuggestionEntry(item: $0) })
    }

    private func seedSessionIfNeeded(textView: TextViewController, cursorPosition: CursorPosition) {
        guard session == nil else { return }

        let items = service.seedItems()
        guard !items.isEmpty else { return }

        let offset = cursorPosition.range.location
        guard let text = textView.textView.textStorage?.string as NSString?,
              offset >= 0, offset <= text.length else { return }

        let start = service.tokenStart(in: text, endingAt: offset)
        session = Session(items: items, replacementRange: NSRange(location: start, length: offset - start))
    }

    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        guard let session, !textView.textView.hasMarkedText() else { return nil }

        let offset = cursorPosition.range.location
        guard let text = textView.textView.textStorage?.string as NSString?,
              offset >= 0, offset <= text.length else { return nil }

        let start = service.tokenStart(in: text, endingAt: offset)
        let length = offset - start
        guard length > 0, length <= maximumPrefixLength else { return nil }

        let prefix = text.substring(with: NSRange(location: start, length: length)).lowercased()
        guard !prefix.isEmpty else { return nil }

        let items = synchronousRefilter(fullItems: session.items, prefix: prefix)
        scheduleRefilter(fullItems: session.items, prefix: prefix)

        return items?.map { SQLSuggestionEntry(item: $0) }
    }

    private func synchronousRefilter(fullItems: [SQLCompletionItem], prefix: String) -> [SQLCompletionItem]? {
        if prefix == lastRefilterPrefix, let cached = lastRefilterItems {
            return cached
        }

        if let lastPrefix = lastRefilterPrefix, prefix.hasPrefix(lastPrefix), let lastItems = lastRefilterItems {
            let narrowed = service.filter(lastItems, prefix: prefix)
            return narrowed.isEmpty ? nil : narrowed
        }

        let filtered = service.filter(fullItems, prefix: prefix)
        return filtered.isEmpty ? nil : filtered
    }

    private func scheduleRefilter(fullItems: [SQLCompletionItem], prefix: String) {
        cursorRefilterTask?.cancel()

        cursorRefilterTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(nanoseconds: self.refilterDebounceNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            let ranked = self.service.rank(fullItems, prefix: prefix)
            guard !Task.isCancelled else { return }

            self.lastRefilterPrefix = prefix
            self.lastRefilterItems = ranked
            Self.logger.debug("refilter cached prefix='\(prefix)' count=\(ranked.count)")
        }
    }

    func completionWindowDidClose() {
        session = nil
        clearRefilterState()
    }

    private func clearRefilterState() {
        cursorRefilterTask?.cancel()
        cursorRefilterTask = nil
        lastRefilterPrefix = nil
        lastRefilterItems = nil
    }

    func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {
        guard !textView.textView.hasMarkedText(),
              let entry = item as? SQLSuggestionEntry,
              let session else { return }

        let text = textView.textView.textStorage?.string as NSString?
        let replaceRange = resolvedReplacementRange(
            in: text,
            cursor: cursorPosition?.range.location,
            fallback: session.replacementRange
        )
        let resolution = SQLCompletionInsertion.resolve(for: entry.item)

        textView.textView.replaceCharacters(in: [replaceRange], with: resolution.text)
        textView.setCursorPositions([
            CursorPosition(range: NSRange(location: replaceRange.location + resolution.cursorOffset, length: 0))
        ])
    }

    private func resolvedReplacementRange(in text: NSString?, cursor: Int?, fallback: NSRange) -> NSRange {
        guard let text, let cursor, cursor >= 0, cursor <= text.length else { return fallback }
        let start = service.tokenStart(in: text, endingAt: cursor)
        return NSRange(location: start, length: cursor - start)
    }
}

// MARK: - SQLSuggestionEntry

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
    var deprecated: Bool { MongoVocabulary.deprecatedCollectionMethods.contains(item.label) }
    var matchedRanges: [Range<Int>] { item.matchedRanges }

    var image: Image {
        Image(systemName: item.kind.iconName)
    }

    var imageColor: Color {
        Color(nsColor: item.kind.iconColor)
    }
}
