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
import SwiftUI
import TableProPluginKit

@MainActor
final class QueryCompletionAdapter: CodeSuggestionDelegate {
    private struct Session {
        var candidates: [SQLCompletionItem]
        var replacementRange: NSRange
    }

    private struct Configuration: Equatable {
        let schemaProvider: ObjectIdentifier?
        let databaseType: DatabaseType?
        let profileRevision: String?
    }

    private var service: QueryCompletionService
    private var configuration: Configuration?
    private var favoriteKeywords: [String: (name: String, query: String)] = [:]
    private var session: Session?

    private let debounceNanoseconds: UInt64 = 50_000_000
    private let maximumPrefixLength = 500

    init(schemaProvider: SQLSchemaProvider?, databaseType: DatabaseType? = nil) {
        self.service = QueryCompletionServiceFactory.make(schemaProvider: schemaProvider, databaseType: databaseType)
    }

    /// Rebuilding the service drops the open completion session, so it happens only when the
    /// inputs actually differ. The editor reconfigures on appear, on a connection change and
    /// again when the profile resolves, and a refresh in any window of the connection bumps the
    /// profile revision the editor's `.task(id:)` keys on: rebuilding unconditionally closed the
    /// popup under whoever was typing.
    func configure(
        schemaProvider: SQLSchemaProvider?,
        databaseType: DatabaseType?,
        profile: QueryCompletionProfile? = nil
    ) {
        let requested = Configuration(
            schemaProvider: schemaProvider.map(ObjectIdentifier.init),
            databaseType: databaseType,
            profileRevision: profile?.revision
        )
        guard requested != configuration else { return }
        configuration = requested
        service = QueryCompletionServiceFactory.make(
            schemaProvider: schemaProvider,
            databaseType: databaseType,
            profile: profile
        )
        service.updateFavoriteKeywords(favoriteKeywords)
        session = nil
    }

    #if DEBUG
    /// Identifies the built service so a test can tell a rebuild from a no-op without reaching
    /// for the private session state a rebuild discards.
    var serviceIdentityForTesting: ObjectIdentifier { ObjectIdentifier(service) }

    init(serviceForTesting service: QueryCompletionService) {
        self.service = service
    }
    #endif

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

        session = Session(candidates: result.candidates, replacementRange: result.replacementRange)

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
        session = Session(candidates: items, replacementRange: NSRange(location: start, length: offset - start))
    }

    /// Filters and ranks the open session's candidates for the token the cursor sits at the end of.
    ///
    /// Ranking happens here, on the keystroke, rather than on a debounced task writing to a cache:
    /// the list handed back is the list the suggestion window shows and preselects its first row
    /// from, so a list ordered for an earlier prefix commits the wrong item on Return. It costs no
    /// debounce, because filtering already matches every candidate in the session and ordering the
    /// survivors is the cheaper half.
    ///
    /// The survivors come from the session's own candidates rather than the previous keystroke's,
    /// so deleting a character widens the list back out.
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

        let ranked = service.rank(session.candidates, prefix: prefix)
        return ranked.isEmpty ? nil : ranked.map { SQLSuggestionEntry(item: $0) }
    }

    func completionWindowDidClose() {
        session = nil
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
