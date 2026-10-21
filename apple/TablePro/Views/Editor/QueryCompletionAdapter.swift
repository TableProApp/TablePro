import AppKit
import SwiftUI
import TableProAutocomplete
import TableProEditorKit
import TableProPluginKit
import TableProTextEngine

@MainActor
final class QueryCompletionAdapter: CodeSuggestionDelegate {
    private struct Session {
        var candidates: [SQLCompletionItem]
        var replacementRange: NSRange
        var tokenStart: Int
        var quotedName: QuotedName?
    }

    // Typing lands before a closed name's close, so the close keeps its distance from the end of the text.
    private struct QuotedName {
        let name: SQLQuotedName
        let closeFromEnd: Int?
    }

    private struct Edit {
        let range: NSRange
        let text: String
        let caret: Int
    }

    private struct Configuration: Equatable {
        let schemaProvider: ObjectIdentifier?
        let databaseType: DatabaseType?
        let profileRevision: String?
        let connectionId: UUID?
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

    // The editor reconfigures on appear, on a connection change and on every refresh, and a rebuild drops the session.
    func configure(
        schemaProvider: SQLSchemaProvider?,
        databaseType: DatabaseType?,
        profile: QueryCompletionProfile? = nil,
        connectionId: UUID? = nil
    ) {
        let requested = Configuration(
            schemaProvider: schemaProvider.map(ObjectIdentifier.init),
            databaseType: databaseType,
            profileRevision: profile?.revision,
            connectionId: connectionId
        )
        guard requested != configuration else { return }
        configuration = requested
        service = QueryCompletionServiceFactory.make(
            schemaProvider: schemaProvider,
            databaseType: databaseType,
            profile: profile,
            connectionId: connectionId
        )
        service.updateFavoriteKeywords(favoriteKeywords)
        session = nil
    }

    #if DEBUG
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
    ) async -> CodeSuggestionResponse? {
        guard !textView.textView.hasMarkedText() else { return nil }

        do {
            try await Task.sleep(nanoseconds: debounceNanoseconds)
        } catch {
            return nil
        }

        guard !textView.textView.hasMarkedText() else { return nil }

        let liveCursorPosition = textView.cursorPositions.first ?? cursorPosition
        // A copy: the storage string keeps changing during the request, and the response names the prefix it ranked.
        let text = NSString(string: textView.textView.textStorage?.string ?? "")
        let offset = liveCursorPosition.range.location
        guard offset >= 0, offset <= text.length else { return nil }

        let localStart = service.tokenStart(in: text, endingAt: offset)

        guard let result = await service.completions(
            in: text,
            at: offset,
            isManualTrigger: isManualTrigger
        ), !Task.isCancelled else {
            return nil
        }

        // The analyzer reads a quoted name whole; the local walk back stops at its last space.
        let tokenStart = result.quotedName == nil ? localStart : result.replacementRange.location
        let prefixRange = NSRange(location: tokenStart, length: offset - tokenStart)
        session = Session(
            candidates: result.candidates,
            replacementRange: result.replacementRange,
            tokenStart: tokenStart,
            quotedName: result.quotedName.map { name in
                QuotedName(name: name, closeFromEnd: name.close.map { text.length - $0 })
            }
        )

        return CodeSuggestionResponse(
            items: result.items.map { SQLSuggestionEntry(item: $0) },
            windowPosition: liveCursorPosition,
            prefix: CodeSuggestionPrefix(range: prefixRange, text: text.substring(with: prefixRange))
        )
    }

    // Ranked per keystroke, not debounced: the window preselects the first row, so a stale order commits the wrong item.
    func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        guard let session, !textView.textView.hasMarkedText() else { return nil }

        let offset = cursorPosition.range.location
        guard let text = textView.textView.textStorage?.string as NSString?,
              offset >= 0, offset <= text.length,
              tokenStart(in: text, endingAt: offset, for: session) == session.tokenStart else { return nil }
        let length = offset - session.tokenStart
        guard length > 0, length <= maximumPrefixLength else { return nil }

        let prefix = text.substring(with: NSRange(location: session.tokenStart, length: length))
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
        let cursor = cursorPosition?.range.location
        let edit = quotedNameEdit(for: entry.item, in: text, cursor: cursor, session: session)
            ?? tokenEdit(for: entry.item, in: text, cursor: cursor, fallback: session.replacementRange)

        textView.textView.replaceCharacters(in: [edit.range], with: edit.text)
        textView.setCursorPositions([CursorPosition(range: NSRange(location: edit.caret, length: 0))])
    }

    private func tokenStart(in text: NSString, endingAt offset: Int, for session: Session) -> Int? {
        guard let quoted = session.quotedName else { return service.tokenStart(in: text, endingAt: offset) }
        return SQLTokenBoundary.segmentStart(inside: quoted.name, in: text, endingAt: offset)
    }

    private func tokenEdit(for item: SQLCompletionItem, in text: NSString?, cursor: Int?, fallback: NSRange) -> Edit {
        let range = resolvedReplacementRange(in: text, cursor: cursor, fallback: fallback)
        let resolution = SQLCompletionInsertion.resolve(for: item)
        return Edit(range: range, text: resolution.text, caret: range.location + resolution.cursorOffset)
    }

    private func resolvedReplacementRange(in text: NSString?, cursor: Int?, fallback: NSRange) -> NSRange {
        guard let text, let cursor, cursor >= 0, cursor <= text.length else { return fallback }
        let start = service.tokenStart(in: text, endingAt: cursor)
        return NSRange(location: start, length: cursor - start)
    }

    // Between the quotes, close doubled and added if missing, caret past it; a qualified column replaces the quotes.
    private func quotedNameEdit(for item: SQLCompletionItem, in text: NSString?, cursor: Int?, session: Session) -> Edit? {
        guard let quoted = session.quotedName, let text, let cursor,
              SQLTokenBoundary.segmentStart(inside: quoted.name, in: text, endingAt: cursor) != nil else { return nil }

        let open = quoted.name.open
        let opener = text.character(at: open)
        let closer = opener == UInt16(UInt8(ascii: "[")) ? UInt16(UInt8(ascii: "]")) : opener
        let close = quoted.closeFromEnd.map { text.length - $0 }.flatMap { close in
            close >= cursor && close < text.length && text.character(at: close) == closer ? close : nil
        }

        if item.isQualifiedReference {
            let resolution = SQLCompletionInsertion.resolve(for: item)
            let token = NSRange(location: open, length: (close.map { $0 + 1 } ?? cursor) - open)
            return Edit(range: token, text: resolution.text, caret: open + resolution.cursorOffset)
        }

        let closeText = String(decoding: [closer], as: UTF16.self)
        let name = item.label.replacingOccurrences(of: closeText, with: closeText + closeText)
        let inner = NSRange(location: open + 1, length: (close ?? cursor) - open - 1)
        return Edit(
            range: inner,
            text: close == nil ? name + closeText : name,
            caret: open + 1 + (name as NSString).length + 1
        )
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
