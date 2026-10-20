import Foundation
import TableProAutocomplete
import TableProDatabase
import TableProModels
import TableProSQLGrammar

nonisolated struct QueryCompletionScope: Equatable, Sendable {
    let connectionId: UUID
    // The driver's identity: a reconnect brings a new driver under the same connection, database and schema.
    let sessionID: ObjectIdentifier?
    let database: String
    let schema: String
    let databaseType: DatabaseType
    let tables: [TableInfo]
    let isRunning: Bool
}

nonisolated struct QuerySuggestion: Identifiable, Equatable, Sendable {
    let id: Int
    let label: String
    let kind: SQLCompletionKind
}

nonisolated struct QueryCompletionEdit: Equatable, Sendable {
    let range: NSRange
    let text: String
    let caret: Int
}

@MainActor
final class QueryCompletionController {
    var onSuggestionsChange: (([QuerySuggestion]) -> Void)?
    private(set) var suggestions: [QuerySuggestion] = []

    private static let suggestionLimit = 8

    private struct Input {
        let text: String
        let selection: NSRange
        let hasMarkedText: Bool
    }

    private struct Position: Equatable {
        let text: String
        let selection: NSRange
    }

    private struct Engine {
        let catalog: QueryCompletionCatalog
        let provider: SQLCompletionProvider
        let databaseType: DatabaseType
    }

    private struct Answer {
        let position: Position
        let items: [SQLCompletionItem]
        let range: NSRange
        let quotedName: SQLQuotedName?
        let databaseType: DatabaseType
    }

    private var scope: QueryCompletionScope?
    private var engine: Engine?
    private var catalogWork: Task<Void, Never>?
    private var latest: Input?
    private var pending: Input?
    private var scheduled: Task<Void, Never>?
    private var running: [Int: Task<Void, Never>] = [:]
    private var generation = 0
    private var answer: Answer?
    private var hiddenAt: Position?

    func update(scope newScope: QueryCompletionScope, readColumns: @escaping QueryColumnReader) {
        let previous = scope
        guard previous != newScope else { return }
        scope = newScope

        guard newScope.databaseType.speaksSQL else {
            engine = nil
            catalogWork = nil
            generation += 1
            show([], answer: nil)
            return
        }

        if let previous, let engine, previous.connectionId == newScope.connectionId,
           previous.sessionID == newScope.sessionID,
           previous.database == newScope.database, previous.schema == newScope.schema,
           previous.databaseType == newScope.databaseType {
            let catalog = engine.catalog
            let tablesChanged = previous.tables != newScope.tables
            if tablesChanged {
                let tables = newScope.tables
                enqueue { await catalog.replaceTables(tables) }
            }
            if previous.isRunning, !newScope.isRunning {
                // The run may have altered a table.
                enqueue { await catalog.markColumnsStale() }
            }
            if previous.isRunning != newScope.isRunning {
                let allowed = !newScope.isRunning
                enqueue { await catalog.setColumnReadsAllowed(allowed) }
            }
            // The run's end asks nothing itself: a column read then would replace the row count and warnings the run
            // left on the session, so the next keystroke reads instead.
            if tablesChanged {
                requestAgain()
            }
            return
        }

        let catalog = QueryCompletionCatalog(
            tables: newScope.tables,
            databaseType: newScope.databaseType,
            schema: newScope.schema.isEmpty ? nil : newScope.schema,
            readColumns: readColumns
        )
        let grammar = SQLLexicalReadings.resolve(
            databaseTypeId: newScope.databaseType.rawValue, declared: nil, session: nil
        ).execution
        engine = Engine(
            catalog: catalog,
            provider: SQLCompletionProvider(catalog: catalog, grammar: grammar, vocabulary: .generic),
            databaseType: newScope.databaseType
        )
        catalogWork = nil
        if newScope.isRunning {
            enqueue { await catalog.setColumnReadsAllowed(false) }
        }
        generation += 1
        show([], answer: nil)
        requestAgain()
    }

    // A keystroke reaches both text view delegate methods, so requests in one main-queue turn run once, on the newest.
    func request(text: String, selection: NSRange, hasMarkedText: Bool) {
        let input = Input(text: text, selection: selection, hasMarkedText: hasMarkedText)
        latest = input
        pending = input
        guard scheduled == nil else { return }
        scheduled = Task { [weak self] in
            self?.startPending()
        }
    }

    func settle() async {
        while true {
            if let scheduled {
                await scheduled.value
            } else if let entry = running.first {
                await entry.value.value
                running[entry.key] = nil
            } else {
                await catalogWork?.value
                return
            }
        }
    }

    func edit(for suggestion: QuerySuggestion, in text: String, selection: NSRange) -> QueryCompletionEdit? {
        guard let answer, answer.position == Position(text: text, selection: selection),
              answer.items.indices.contains(suggestion.id) else { return nil }
        let item = answer.items[suggestion.id]
        guard item.label == suggestion.label, item.kind == suggestion.kind else { return nil }

        let source = text as NSString
        generation += 1
        switch item.kind {
        case .table, .view, .column, .schema, .alias:
            let edit = Self.nameEdit(for: item, in: answer, text: source)
            // The exact match would lead again and Tab would insert it twice, so the bar waits for the next edit.
            hiddenAt = Position(
                text: source.replacingCharacters(in: edit.range, with: edit.text),
                selection: NSRange(location: edit.caret, length: 0)
            )
            show([], answer: nil)
            return edit
        case .keyword, .operator:
            return Self.keywordEdit(for: item, replacing: answer.range, in: source)
        case .function, .favorite:
            let insertion = SQLCompletionInsertion.resolve(for: item)
            return QueryCompletionEdit(
                range: answer.range,
                text: insertion.text,
                caret: answer.range.location + insertion.cursorOffset
            )
        }
    }

    // A read already sent can issue its next statement mid-run, which ends a PostgreSQL stream, so a run waits for it.
    func finishColumnReads() async {
        await engine?.catalog.finishReads()
    }

    func hide() {
        hiddenAt = latest.map { Position(text: $0.text, selection: $0.selection) }
        generation += 1
        show([], answer: nil)
    }

    static func columnReader(session: @escaping @MainActor () -> ConnectionSession?) -> QueryColumnReader {
        { table, schema in
            guard let driver = await session()?.driver else { return nil }
            return try await driver.fetchColumns(table: table, schema: schema)
        }
    }

    private func requestAgain() {
        guard let latest else { return }
        request(text: latest.text, selection: latest.selection, hasMarkedText: latest.hasMarkedText)
    }

    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = catalogWork
        catalogWork = Task {
            await previous?.value
            await work()
        }
    }

    private func startPending() {
        scheduled = nil
        guard let input = pending else { return }
        pending = nil
        generation += 1
        let ticket = generation
        running[ticket] = Task { [weak self] in
            await self?.compute(input, ticket: ticket)
        }
    }

    private func compute(_ input: Input, ticket: Int) async {
        defer { running[ticket] = nil }
        guard ticket == generation else { return }

        let position = Position(text: input.text, selection: input.selection)
        if hiddenAt != position { hiddenAt = nil }
        guard let engine, hiddenAt == nil, !input.hasMarkedText, input.selection.length == 0 else {
            show([], answer: nil)
            return
        }

        let text = input.text as NSString
        let caret = min(max(input.selection.location, 0), text.length)
        guard !SQLCompletionTriggerPolicy.suppressesAfterStatementBreak(in: text, at: caret) else {
            show([], answer: nil)
            return
        }

        let catalogWork = self.catalogWork
        await catalogWork?.value
        guard ticket == generation else { return }

        let window = SQLCompletionWindow.cut(text, around: caret)
        let session = await engine.provider.completionSession(
            text: window.text,
            cursorPosition: caret - window.start,
            forcedTableReferences: nil
        )
        guard ticket == generation else { return }

        let context = session.context
        // iOS has no manual trigger and the bar never covers the text, so it fills at every code position.
        guard !SQLCompletionTriggerPolicy.suppressesEmptyPrefix(context, isManualTrigger: true) else {
            show([], answer: nil)
            return
        }
        let items = SQLCompletionCasing.applied(
            to: Array(session.items.prefix(Self.suggestionLimit)),
            typedPrefix: context.prefix,
            policy: .default
        )
        let range = NSRange(location: context.prefixRange.lowerBound + window.start, length: context.prefixRange.count)
        let quotedName = context.quotedName.map { name in
            SQLQuotedName(open: name.open + window.start, close: name.close.map { $0 + window.start })
        }
        show(items, answer: Answer(
            position: position,
            items: items,
            range: range,
            quotedName: quotedName,
            databaseType: engine.databaseType
        ))
    }

    private func show(_ items: [SQLCompletionItem], answer: Answer?) {
        self.answer = items.isEmpty ? nil : answer
        let list = items.enumerated().map { index, item in
            QuerySuggestion(id: index, label: item.label, kind: item.kind)
        }
        guard list != suggestions else { return }
        suggestions = list
        onSuggestionsChange?(list)
    }

    private static func nameEdit(for item: SQLCompletionItem, in answer: Answer, text: NSString) -> QueryCompletionEdit {
        let insertion = SQLCompletionInsertion.resolve(for: item)
        guard let quoted = answer.quotedName else {
            return QueryCompletionEdit(
                range: answer.range,
                text: insertion.text,
                caret: answer.range.location + insertion.cursorOffset
            )
        }
        if let close = quoted.close {
            if isQualifiedColumn(item, for: answer.databaseType) {
                let token = NSRange(location: quoted.open, length: close + 1 - quoted.open)
                return QueryCompletionEdit(
                    range: token,
                    text: insertion.text,
                    caret: token.location + insertion.cursorOffset
                )
            }
            let closeText = text.substring(with: NSRange(location: close, length: 1))
            let name = item.label.replacingOccurrences(of: closeText, with: closeText + closeText)
            let inner = NSRange(location: quoted.open + 1, length: close - quoted.open - 1)
            return QueryCompletionEdit(range: inner, text: name, caret: inner.location + (name as NSString).length + 1)
        }
        // An opening quote with no close of its own is overwritten by the quoted name, so it is never left doubled.
        let typed = NSRange(location: quoted.open, length: NSMaxRange(answer.range) - quoted.open)
        return QueryCompletionEdit(range: typed, text: insertion.text, caret: typed.location + insertion.cursorOffset)
    }

    // `o.total` is two names, so it cannot go inside the quotes typed around one.
    private static func isQualifiedColumn(_ item: SQLCompletionItem, for type: DatabaseType) -> Bool {
        item.kind == .column && item.label.contains(".")
            && item.insertText != CompletionIdentifierQuoting.quoted(item.label, for: type)
    }

    private static func keywordEdit(
        for item: SQLCompletionItem,
        replacing range: NSRange,
        in text: NSString
    ) -> QueryCompletionEdit {
        let word = SQLCompletionInsertion.resolve(for: item).text
        let length = (word as NSString).length
        let end = NSMaxRange(range)
        guard length > 1 else {
            return QueryCompletionEdit(range: range, text: word, caret: range.location + length)
        }
        if end < text.length, isWhitespace(text.character(at: end)) {
            return QueryCompletionEdit(range: range, text: word, caret: range.location + length + 1)
        }
        return QueryCompletionEdit(range: range, text: word + " ", caret: range.location + length + 1)
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }
}
