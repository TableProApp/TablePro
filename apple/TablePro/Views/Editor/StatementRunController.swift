//
//  StatementRunController.swift
//  TablePro
//

import AppKit
import TableProEditorKit
import TableProPluginKit
import TableProSQLGrammar
import TableProTextEngine

/// Which way a statement navigation command moves the caret.
enum StatementNavigationDirection {
    case previous
    case next
}

// The gutter's run controls and the caret's statement band both come from the scanner execution uses, so a control
// never offers to run something other than what it is drawn beside. The band runs on every caret move, so a SQL
// document resolves it through `SQLStatementCursorIndex`, which rescans only from the last boundary before the caret,
// and a JavaScript or Redis document through a `QueryStatementCaretTable` read once per text.
// The controls need every statement, a full pass of 31ms at the size limit, so on a large document that refresh is
// debounced and scanned off the main thread.
@MainActor
final class StatementRunController {
    /// The largest document decorations are computed for, in UTF-16 units.
    ///
    /// The same threshold syntax highlighting and code folding stop at, so an editor that has given up on colouring a
    /// document does not still be walking it for statement boundaries.
    nonisolated static let defaultSizeLimit = 2_000_000

    /// How long typing has to pause before the run controls are recomputed.
    nonisolated static let refreshDelay: Duration = .milliseconds(150)

    /// Below this length the controls are recomputed on the keystroke rather than on the pause.
    ///
    /// A full pass is 6ms at 190KB and 31ms at the size limit, so debouncing is only worth its staleness on a large
    /// document. Measured; see `StatementRunPerformanceGuardTests`.
    static let synchronousRefreshLimit = 64_000

    var sizeLimit = StatementRunController.defaultSizeLimit
    var grammar: SQLLexicalGrammar = .ansi {
        didSet {
            if grammar != oldValue {
                caretIndex = nil
                dropRememberedStatement()
            }
        }
    }

    /// How the document divides into statements. JavaScript engines do not end a statement at every
    /// semicolon, so the gutter controls and the caret band have to ask the same splitter execution does.
    var statementModel: QueryStatementModel = .sql {
        didSet {
            if statementModel != oldValue {
                caretIndex = nil
                caretTable = nil
                dropRememberedStatement()
            }
        }
    }

    // The band asks on every caret move, so a document keeps its statement boundaries between edits.
    private var caretIndex: SQLStatementCursorIndex?
    private var caretTable: QueryStatementCaretTable?
    private weak var caretIndexStorage: NSTextStorage?
    private var caretIndexEdits: StorageEditObservation?
    // Completion asks for the caret the band just resolved, so a long statement is not scanned twice per key.
    private var rememberedStatement: (cursor: Int, statement: SQLStatementScanner.LocatedStatement)?
    // An index warmed off the main thread comes back after the text may have moved on. `indexEpoch` moves when the
    // index is dropped; the edits since the warm began trim it to the text as it is now.
    private var indexEpoch = 0
    private var editSerial = 0
    private var recentEditLocations: [Int] = []
    private static let recentEditLimit = 512

    var caretIndexUnitsScanned: Int {
        caretIndex?.unitsScanned ?? 0
    }

    private(set) var caretTableReads = 0

    /// Called with the SQL the pressed control stands for, read from the document at the moment of the press, and
    /// where that SQL starts in the document.
    ///
    /// The text is passed rather than only the range, because the caller substrings a different string: the SwiftUI
    /// binding the tab holds lags the text view, and a range resolved against the wrong one silently truncates. A
    /// `DELETE ... WHERE ...` cut short is still a statement the driver will accept. The offset rides alongside so
    /// the result can point back at the statement, and it is only ever used through ``StatementAnchor``, which
    /// re-resolves it against the live query and falls back to matching the statement itself. A range that was a
    /// moment stale therefore corrects itself rather than sending the caret somewhere arbitrary.
    var onRun: ((String, Int) -> Bool)?

    /// Whether the band is drawn at all.
    ///
    /// Held here rather than only in the theme, which resolves the band to a transparent colour when the setting is
    /// off, because a band nobody can see is not worth resolving the caret's statement for on every keystroke.
    var isHighlightEnabled = true

    private var pendingRefresh: Task<Void, Never>?
    /// Latched because the owning view writes it from `body`, which runs before the editor has a controller to
    /// receive it. Without this an editor created while its tab is already running draws its controls undimmed.
    private var isEnabled = true

    func install(on controller: TextViewController) {
        controller.statementRunAccessibilityLabel = String(localized: "Run statement")
        controller.statementRunAccessibilityLabelFormat = String(
            localized: "Run the statement starting on line %d"
        )
        controller.onRunStatement = { [weak self] statement in
            self?.run(statement, in: controller)
        }
        controller.statementBoundaryProvider = { [weak self, weak controller] offset, forward in
            self?.statementBoundary(from: offset, forward: forward, in: controller)
        }
        controller.statementRunControlsEnabled = isEnabled
        refreshControls(in: controller)
        refreshHighlight(in: controller)
    }

    /// Whether pressing a run control does anything right now.
    ///
    /// The controls stay drawn while a query runs and go dim, rather than disappearing and coming back, so the gutter
    /// does not flicker for the length of the query.
    ///
    /// Guarded on the current value because the owning view writes this from `body`, which SwiftUI runs far more often
    /// than the execution state changes, and every write marks the gutter for redisplay.
    func setEnabled(_ isEnabled: Bool, in controller: TextViewController?) {
        self.isEnabled = isEnabled
        guard let controller, controller.statementRunControlsEnabled != isEnabled else { return }
        controller.statementRunControlsEnabled = isEnabled
    }

    /// Queues a recompute of the run controls. Call after the document changes.
    ///
    /// Small documents skip the queue entirely, so the ranges the gutter draws from stay in step with the text on
    /// every keystroke rather than for everything but the last 150ms of typing.
    func scheduleControlsRefresh(in controller: TextViewController?) {
        pendingRefresh?.cancel()
        guard let controller, let textView = controller.textView else { return }

        if textView.textStorage.length <= Self.synchronousRefreshLimit {
            refreshControls(in: controller)
            return
        }

        pendingRefresh = Task { [weak self, weak controller] in
            try? await Task.sleep(for: Self.refreshDelay)
            guard !Task.isCancelled, let self, let controller else { return }
            self.refreshControls(in: controller)
        }
    }

    /// Recomputes the run controls without waiting out the debounce.
    ///
    /// A small document is scanned here, so its controls are in step when this returns. A larger one is scanned off
    /// the main thread on a snapshot of the text, and its controls are replaced only if no edit landed meanwhile:
    /// the edit schedules a scan of its own.
    func refreshControls(in controller: TextViewController?) {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        guard let controller, let textView = controller.textView, let storage = textView.textStorage else { return }

        guard storage.length <= sizeLimit else {
            controller.runnableStatements = []
            return
        }

        guard storage.length > Self.synchronousRefreshLimit else {
            controller.runnableStatements = Self.statementRuns(in: textView.string, model: statementModel, grammar: grammar)
            return
        }

        if caretIndexStorage !== storage {
            observeEdits(on: storage)
        }
        // Started on the next turn of the main actor, so a call made inside an editing batch reads the text, and
        // counts the edit, after the storage has finished processing it.
        pendingRefresh = Task { [weak self, weak controller, weak storage] in
            guard let self, let controller, let storage, controller.textView?.textStorage === storage else { return }
            // Bridging the storage shares its buffer, so the snapshot costs nothing until an edit touches a block.
            let text = controller.textView.string
            let serial = self.editSerial
            let model = self.statementModel
            let grammar = self.grammar
            let runs = await Self.scanStatementRuns(in: text, model: model, grammar: grammar)
            guard !Task.isCancelled, controller.textView?.textStorage === storage,
                  self.editSerial == serial, self.statementModel == model, self.grammar == grammar else { return }
            controller.runnableStatements = runs
        }
    }

    @concurrent
    nonisolated private static func scanStatementRuns(
        in text: String,
        model: QueryStatementModel,
        grammar: SQLLexicalGrammar
    ) async -> [StatementRun] {
        statementRuns(in: text, model: model, grammar: grammar)
    }

    nonisolated private static func statementRuns(
        in text: String,
        model: QueryStatementModel,
        grammar: SQLLexicalGrammar
    ) -> [StatementRun] {
        QueryStatementScanner
            .navigableStatements(in: text, model: model, grammar: grammar)
            .map { StatementRun(range: $0.contentRange) }
    }

    /// Moves the caret to the start of the statement before or after the one it is in.
    ///
    /// Rescans rather than reading the drawn controls, which a large document lets fall up to one debounce behind the
    /// text. Anchors on the first caret and leaves a single one behind, matching how the band picks its statement.
    func moveCursor(_ direction: StatementNavigationDirection, in controller: TextViewController?) {
        guard let controller, let textView = controller.textView else { return }
        let text = textView.string
        guard (text as NSString).length <= sizeLimit else { return }
        guard let caret = controller.cursorPositions.first?.range.location else { return }

        guard let destination = statementStart(direction, from: caret, in: text) else { return }
        controller.moveCursor(to: destination)
    }

    /// The offset `Option+Shift+Up` and `Option+Shift+Down` extend the selection to.
    ///
    /// Forward reaches the far edge of the last statement rather than the start of the next one, or the last
    /// statement's own body could never be selected.
    func statementBoundary(from offset: Int, forward: Bool, in controller: TextViewController?) -> Int? {
        guard let controller, let textView = controller.textView else { return nil }
        let text = textView.string
        guard (text as NSString).length <= sizeLimit else { return nil }
        guard forward else {
            return QueryStatementScanner.statementStart(before: offset, in: text, model: statementModel, grammar: grammar)
        }
        return QueryStatementScanner.statementSelectionEnd(
            after: offset, in: text, model: statementModel, grammar: grammar
        )
    }

    /// The statement the caret is in and where it starts, or `nil` when there is nothing to run there.
    ///
    /// Capped the same way navigation is, so run-and-advance cannot run without also being able to advance.
    func statementAtCursor(in controller: TextViewController?) -> (sql: String, offset: Int)? {
        guard let controller, let textView = controller.textView else { return nil }
        let text = textView.string
        guard (text as NSString).length <= sizeLimit else { return nil }
        guard let selection = controller.cursorPositions.first, selection.range.length == 0 else { return nil }

        let located = statement(at: selection.range.location, in: text, storage: textView.textStorage)
        guard located.hasContent, located.contentRange.length > 0 else { return nil }
        return (
            (text as NSString).substring(with: located.contentRange),
            located.contentRange.location
        )
    }

    private func statementStart(_ direction: StatementNavigationDirection, from offset: Int, in text: String) -> Int? {
        switch direction {
        case .previous:
            return QueryStatementScanner.statementStart(before: offset, in: text, model: statementModel, grammar: grammar)
        case .next:
            return QueryStatementScanner.statementStart(after: offset, in: text, model: statementModel, grammar: grammar)
        }
    }

    // `text` is the storage's text as it is now.
    func statement(at cursor: Int, in text: String, storage: NSTextStorage?) -> SQLStatementScanner.LocatedStatement {
        guard let storage else {
            return QueryStatementScanner.locatedStatementAtCursor(
                in: text, cursorPosition: cursor, model: statementModel, grammar: grammar
            )
        }
        return indexedStatement(at: cursor, in: text, storage: storage)
    }

    /// Where the statement holding `offset` starts, or 0 where the index does not answer for this document or grammar.
    ///
    /// A statement never starts inside a literal or a comment, so a reader that has to know whether `offset` is in one
    /// can begin here rather than at the top of the document. Not remembered as the caret's statement: `offset` is
    /// rarely the caret.
    func statementStart(containing offset: Int, in textView: TextView, grammar requested: SQLLexicalGrammar) -> Int {
        guard statementModel == .sql, grammar == requested,
              let storage = textView.textStorage, storage.length <= sizeLimit else { return 0 }
        if caretIndexStorage !== storage {
            observeEdits(on: storage)
        }
        if storage.editedMask.contains(.editedCharacters) {
            textDidChange(at: storage.editedRange.location)
        }
        if caretIndex == nil {
            caretIndex = SQLStatementCursorIndex(grammar: grammar)
        }
        let start = caretIndex?.statementAtCursor(offset, in: textView.string).offset ?? 0
        return min(start, offset)
    }

    // Only where the band keeps the index warm at the caret. `text` is the storage's text as it is now.
    func maintainedStatement(
        at cursor: Int,
        in text: String,
        storage: NSTextStorage
    ) -> (statement: SQLStatementScanner.LocatedStatement, grammar: SQLLexicalGrammar)? {
        guard statementModel == .sql, isHighlightEnabled, (text as NSString).length <= sizeLimit else { return nil }
        return (indexedStatement(at: cursor, in: text, storage: storage), grammar)
    }

    // A document the band does not keep is scanned off the main thread on the caller's snapshot. The index the scan
    // leaves is kept for the next request, trimmed to any edit made while it ran.
    func warmedStatement(
        at cursor: Int,
        in text: String,
        storage: NSTextStorage,
        grammar requested: SQLLexicalGrammar
    ) async -> SQLStatementScanner.LocatedStatement? {
        guard statementModel == .sql, grammar == requested else { return nil }
        if let maintained = maintainedStatement(at: cursor, in: text, storage: storage) {
            return maintained.statement
        }
        let ticket = beginWarm(storage: storage)
        if let remembered = rememberedStatement, remembered.cursor == cursor {
            return remembered.statement
        }
        let (statement, warmed) = await Self.locate(cursor, in: text, using: ticket.index)
        finishWarm(ticket, warmed: warmed, cursor: cursor, statement: statement)
        return statement
    }

    struct WarmTicket {
        let epoch: Int
        let serial: Int
        let index: SQLStatementCursorIndex
    }

    func beginWarm(storage: NSTextStorage) -> WarmTicket {
        if caretIndexStorage !== storage {
            observeEdits(on: storage)
        }
        if storage.editedMask.contains(.editedCharacters) {
            textDidChange(at: storage.editedRange.location)
        }
        return WarmTicket(epoch: indexEpoch, serial: editSerial, index: caretIndex ?? SQLStatementCursorIndex(grammar: grammar))
    }

    // Dropped when the index was dropped meanwhile, or when more edits came in than are remembered.
    func finishWarm(
        _ ticket: WarmTicket,
        warmed: SQLStatementCursorIndex,
        cursor: Int,
        statement: SQLStatementScanner.LocatedStatement
    ) {
        let missed = editSerial - ticket.serial
        guard ticket.epoch == indexEpoch, missed <= recentEditLocations.count else { return }
        var index = warmed
        if let floor = recentEditLocations.suffix(missed).min() {
            index.textDidChange(at: floor)
        } else {
            rememberedStatement = (cursor, statement)
        }
        caretIndex = index
    }

    @concurrent
    nonisolated private static func locate(
        _ cursor: Int,
        in text: String,
        using index: SQLStatementCursorIndex
    ) async -> (SQLStatementScanner.LocatedStatement, SQLStatementCursorIndex) {
        var index = index
        let statement = index.statementAtCursor(cursor, in: text)
        return (statement, index)
    }

    /// Moves the band to the statement the caret is in. Call after the selection changes.
    func refreshHighlight(in controller: TextViewController?) {
        guard let controller else { return }
        controller.highlightedStatementRange = highlightRange(in: controller)
    }

    func clear(in controller: TextViewController?) {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        caretIndex = nil
        caretTable = nil
        dropRememberedStatement()
        caretIndexStorage = nil
        caretIndexEdits = nil
        controller?.runnableStatements = []
        controller?.highlightedStatementRange = nil
        controller?.onRunStatement = nil
        controller?.statementBoundaryProvider = nil
    }

    // MARK: - Private

    /// Resolves what a pressed control stands for against the document as it is right now.
    ///
    /// The control was drawn from a range the last scan produced, and on a large document that scan can be up to one
    /// debounce old. Rather than trust the range, this re-reads the statement that currently starts there and refuses
    /// the press if the document has moved under it, which is fail-closed: the worst outcome is a click that does
    /// nothing and a gutter that redraws.
    private func run(_ statement: StatementRun, in controller: TextViewController) {
        guard let textView = controller.textView else { return }
        let text = textView.string
        let length = (text as NSString).length
        guard statement.range.location < length else {
            refreshControls(in: controller)
            return
        }

        let resolved = self.statement(at: statement.range.location, in: text, storage: textView.textStorage)
        guard resolved.hasContent, resolved.contentRange == statement.range else {
            refreshControls(in: controller)
            return
        }

        _ = onRun?(
            (text as NSString).substring(with: resolved.contentRange),
            resolved.contentRange.location
        )
    }

    // A selection runs verbatim, so the band steps aside for it. Several carets resolve through the first, as execution does.
    private func highlightRange(in controller: TextViewController) -> NSRange? {
        guard isHighlightEnabled,
              let textView = controller.textView,
              let selection = controller.cursorPositions.first,
              selection.range.length == 0,
              textView.textStorage.length <= sizeLimit else {
            return nil
        }

        let text = textView.string
        let located = statement(at: selection.range.location, in: text, storage: textView.textStorage)
        guard located.hasContent, located.contentRange.length > 0 else { return nil }
        return located.contentRange
    }

    private func indexedStatement(
        at cursor: Int,
        in text: String,
        storage: NSTextStorage
    ) -> SQLStatementScanner.LocatedStatement {
        if caretIndexStorage !== storage {
            observeEdits(on: storage)
        }
        // Inside an editing batch the text has changed but the storage has not posted its notification yet.
        if storage.editedMask.contains(.editedCharacters) {
            textDidChange(at: storage.editedRange.location)
        }
        if let remembered = rememberedStatement, remembered.cursor == cursor {
            return remembered.statement
        }
        let statement = resolvedStatement(at: cursor, in: text)
        rememberedStatement = (cursor, statement)
        return statement
    }

    private func resolvedStatement(at cursor: Int, in text: String) -> SQLStatementScanner.LocatedStatement {
        guard statementModel == .sql else {
            if caretTable == nil {
                caretTable = QueryStatementCaretTable(text: text, model: statementModel)
                caretTableReads += 1
            }
            return caretTable?.statement(atCursor: cursor)
                ?? QueryStatementScanner.locatedStatementAtCursor(
                    in: text, cursorPosition: cursor, model: statementModel, grammar: grammar
                )
        }
        if caretIndex == nil {
            caretIndex = SQLStatementCursorIndex(grammar: grammar)
        }
        return caretIndex?.statementAtCursor(cursor, in: text)
            ?? SQLStatementScanner.locatedStatementAtCursor(in: text, cursorPosition: cursor, grammar: grammar)
    }

    private func textDidChange(at location: Int) {
        caretIndex?.textDidChange(at: location)
        caretTable = nil
        rememberedStatement = nil
        editSerial += 1
        recentEditLocations.append(location)
        if recentEditLocations.count > Self.recentEditLimit {
            recentEditLocations.removeFirst(recentEditLocations.count - Self.recentEditLimit)
        }
    }

    private func dropRememberedStatement() {
        rememberedStatement = nil
        indexEpoch &+= 1
        recentEditLocations.removeAll()
    }

    private func observeEdits(on storage: NSTextStorage) {
        caretIndex = nil
        caretTable = nil
        dropRememberedStatement()
        caretIndexStorage = storage
        // Every way the text changes passes through the storage, including the ones that skip the editor's delegate.
        let token = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: storage,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.caretIndexStorageDidProcessEditing() }
        }
        caretIndexEdits = StorageEditObservation(token)
    }

    private func caretIndexStorageDidProcessEditing() {
        guard let storage = caretIndexStorage, storage.editedMask.contains(.editedCharacters) else { return }
        textDidChange(at: storage.editedRange.location)
    }
}

private final class StorageEditObservation {
    private let token: any NSObjectProtocol

    init(_ token: any NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
