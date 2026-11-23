import AppKit
import Combine
import os
import TableProAutocomplete
import TableProEditorKit
import TableProPluginKit
import TableProSQLGrammar
import TableProTextEngine

@MainActor
final class SQLEditorCoordinator: ObservableObject, TextViewCoordinator, TextViewDelegate {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "SQLEditorCoordinator")

    // Above this length inline AI is suspended, like highlighting, so a large document is not sent on every keystroke.
    private static let languageServiceLengthLimit = EditorHighlighting.maxHighlightableCharacters

    weak var controller: TextViewController?
    private let diagnosticsClock: any Clock<Duration>
    private lazy var diagnosticsController = QueryDiagnosticsController(
        databaseType: databaseType,
        clock: diagnosticsClock
    )
    private let statementRunController = StatementRunController()
    var schemaProvider: SQLSchemaProvider?
    var databaseScope: DatabaseScope?
    private let inlineAccessGate: AIConnectionAccessGate = .live
    private var contextMenu: AIEditorContextMenu?
    private var inlineSuggestionManager: InlineSuggestionManager?
    private var aiChatInlineSource: AIChatInlineSource?
    private var appleIntelligenceInlineSource: AppleIntelligenceInlineSource?
    private var copilotDocumentSync: CopilotDocumentSync?
    private var copilotInlineSource: CopilotInlineSource?
    private var editorSettingsCancellable: AnyCancellable?
    private var aiSettingsCancellable: AnyCancellable?
    private var connectionAccessCancellable: AnyCancellable?
    private var lastInlineSourceKind: InlineSuggestionSourceKind = .off
    // Debounced so a keystroke does not recompute the highlight viewport.
    private var frameChangeTask: Task<Void, Never>?
    private var isUppercasing = false
    private var wasEditorFocused = false
    private var didDestroy = false
    private var focusClaimPending = false

    // One way: destroy() runs when the editor is dismantled, which it never comes back from.
    var isDestroyed: Bool { didDestroy }

    private var hasInstalledEditorServices = false
    private weak var windowSentinel: WindowAccessorView?

    private var cursorRestorePending: NSRange?

    var pendingFocusClaim: Bool { focusClaimPending }

    var pendingCursorRestore: NSRange? { cursorRestorePending }

    init(diagnosticsClock: any Clock<Duration> = ContinuousClock()) {
        self.diagnosticsClock = diagnosticsClock
    }

    func scheduleEditorFocusClaim() {
        // Query tabs share one editor, which installs only once, so a later tab's claim is taken here.
        if hasInstalledEditorServices, !isDestroyed, let textView = controller?.textView, let window = textView.window {
            window.makeFirstResponder(textView)
            return
        }
        focusClaimPending = true
    }

    // Set from body many times before the text view exists, so it latches once; the cursor binding would fight live typing.
    func scheduleCursorRestore(_ range: NSRange) {
        guard !hasInstalledEditorServices else { return }
        cursorRestorePending = range
    }

    private var foldRestorePending: [Range<Int>]?

    // Replayed once, like the cursor, because the fold state reported back is written on every collapse.
    func scheduleFoldRestore(_ ranges: [Range<Int>]) {
        guard !hasInstalledEditorServices, !ranges.isEmpty else { return }
        foldRestorePending = ranges
    }

    // Replacing the document already dropped the outgoing tab's folds, so nothing is cleared or reported here.
    func repointFolds(to ranges: [Range<Int>]?) {
        guard let controller else {
            foldRestorePending = ranges
            return
        }
        guard let ranges, !ranges.isEmpty else { return }
        controller.restoreCollapsedFolds(ranges)
    }

    var vimDocumentMarks: VimDocumentMarks? {
        guard let vimEngine else { return pendingVimDocumentMarks }
        let marks = vimEngine.documentMarks
        return marks.isEmpty ? nil : marks
    }

    func restoreVimDocumentMarks(_ marks: VimDocumentMarks) {
        guard let vimEngine else {
            pendingVimDocumentMarks = marks
            return
        }
        vimEngine.restoreDocumentMarks(marks)
    }

    @Published private(set) var vimMode: VimMode = .normal
    private var vimEngine: VimEngine?
    // Vim is installed once the editor is in a window, so marks restored before that wait here.
    private var pendingVimDocumentMarks: VimDocumentMarks?
    private var vimKeyInterceptor: VimKeyInterceptor?
    private var emacsKeyInterceptor: EmacsKeyInterceptor?
    private var commandHandler = VimCommandLineHandler()
    private var vimCursorManager: VimCursorManager?
    var onCloseTab: (() -> Void)?
    var onExecuteQuery: (() -> Void)?
    var onSelectTab: ((Int) -> Void)?
    var onSelectAdjacentTab: ((Int) -> Void)?
    var tabCount: (() -> Int)?
    var onRunStatement: ((String, Int) -> Bool)?
    var currentAIAvailability: (() -> AIQueryActionAvailability)?
    var onAIAction: ((AIQueryAction, AIQueryTarget) -> Void)?
    var onSaveAsFavorite: ((String) -> Void)?
    var onShareQuery: ((String) -> Void)?
    var databaseType: DatabaseType?
    var tabID: UUID?
    var connectionId: UUID?
    var sourceFileURL: URL?
    // SQLEditorController sets this from the live session.
    private(set) var sessionGrammar: SQLLexicalGrammar?

    var lexicalGrammar: SQLLexicalGrammar {
        sessionGrammar ?? (databaseType ?? .mysql).lexicalGrammar
    }

    // Guards cursor propagation: a find-panel highlight that reached SwiftUI would re-render and break its focus.
    var isEditorFirstResponder: Bool {
        guard let textView = controller?.textView else { return false }
        return textView.window?.firstResponder === textView
    }

    deinit {
        frameChangeTask?.cancel()
    }

    private func cleanupMonitors() {
        editorSettingsCancellable = nil
        aiSettingsCancellable = nil
        connectionAccessCancellable = nil
        frameChangeTask?.cancel()
        frameChangeTask = nil
    }

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller

        // `prepareCoordinator` runs during `TextViewController.init`, before the view is in
        // a window. A sentinel view reports the real moment instead of guessing at it with
        // a sleep, which raced the first-responder claim on a slow launch.
        // The sentinel lives on the controller's own view, so holding the controller strongly
        // here would be a cycle through the view hierarchy and leak the whole editor: text
        // storage, parse tree and layout manager. It also has one job, so it retires the moment
        // it reports rather than waiting for teardown to remember it.
        let sentinel = WindowAccessorView(frame: .zero)
        windowSentinel = sentinel
        sentinel.onWindow = { [weak self, weak controller, weak sentinel] _ in
            sentinel?.onWindow = nil
            sentinel?.removeFromSuperview()
            guard let controller else { return }
            self?.installEditorServices(controller: controller)
        }
        controller.view.addSubview(sentinel)
    }

    private func releaseWindowSentinel() {
        windowSentinel?.onWindow = nil
        windowSentinel?.removeFromSuperview()
        windowSentinel = nil
    }

    private func installEditorServices(controller: TextViewController) {
        guard !hasInstalledEditorServices, !isDestroyed else { return }
        hasInstalledEditorServices = true

        installAIContextMenu(controller: controller)
        installFoldPreview(controller: controller)
        installStatementRunControls(controller: controller)
        installInlineSuggestionManager(controller: controller)
        diagnosticsController.configure(databaseType: databaseType, grammar: lexicalGrammar)
        diagnosticsController.install(on: controller)
        diagnosticsController.scheduleRefresh(for: controller)
        applyKeyBindings(controller: controller)
        installEditorSettingsObserver(controller: controller)

        guard let textView = controller.textView else { return }
        EditorEventRouter.shared.register(self, textView: textView)

        if let window = textView.window {
            let claimPending = focusClaimPending
            var made = false
            if claimPending {
                focusClaimPending = false
                made = window.makeFirstResponder(textView)
            } else if window.firstResponder == nil || window.firstResponder === window {
                made = window.makeFirstResponder(textView)
            }
            Self.logger.debug("Editor focus claim: pending=\(claimPending) isKey=\(window.isKeyWindow) made=\(made)")
        }

        if let restored = cursorRestorePending {
            cursorRestorePending = nil
            let clamped = restored.clampedToTextLength(textView.textStorage.length)
            controller.setCursorPositions([CursorPosition(range: clamped)], scrollToVisible: true)
        } else if controller.cursorPositions.isEmpty {
            controller.setCursorPositions([CursorPosition(range: NSRange(location: 0, length: 0))])
        }

        if let folds = foldRestorePending {
            foldRestorePending = nil
            controller.restoreCollapsedFolds(folds)
        }
    }

    // Marks move with typed, pasted and undone text, which never passes through the Vim engine.
    func textView(_ textView: TextView, willReplaceContentsIn range: NSRange, with string: String) {
        guard let vimEngine else { return }
        let undoManager = textView.undoManager
        let source: VimEditSource = undoManager?.isUndoing == true ? .undo : undoManager?.isRedoing == true ? .redo : .edit
        vimEngine.textWillChange(in: range, with: string, source: source)
    }

    func textView(_ textView: TextView, didReplaceContentsIn range: NSRange, with string: String) {
        vimEngine?.invalidateLineCache()
        foldPreview.dismiss()

        let isLargeDocument = textView.textStorage.length > Self.languageServiceLengthLimit

        Task { [weak self] in
            if !isLargeDocument {
                self?.inlineSuggestionManager?.handleTextChange()
            }
            self?.vimCursorManager?.updatePosition()
        }

        frameChangeTask?.cancel()
        frameChangeTask = Task { [weak controller] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let controller, let textView = controller.textView else { return }
            NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: textView)
        }

        uppercaseKeywordIfNeeded(textView: textView, range: range, string: string)
        statementRunController.scheduleControlsRefresh(in: controller)
        refreshDiagnostics(in: controller, isLargeDocument: isLargeDocument)
    }

    func textViewDidReplaceDocument(controller: TextViewController) {
        vimEngine?.invalidateLineCache()
        vimEngine?.documentDidReplace()
        pendingVimDocumentMarks = nil
        foldPreview.dismiss()
        inlineSuggestionManager?.dismissSuggestion()
        copilotDocumentSync?.textViewDidReplaceDocument()
        statementRunController.refreshControls(in: controller)
        statementRunController.refreshHighlight(in: controller)
        diagnosticsController.clear(in: controller)
        guard controller.textView.textStorage.length <= Self.languageServiceLengthLimit else { return }
        diagnosticsController.scheduleRefresh(for: controller)
    }

    private func refreshDiagnostics(in controller: TextViewController?, isLargeDocument: Bool) {
        guard !isLargeDocument else {
            diagnosticsController.clear(in: controller)
            return
        }
        diagnosticsController.scheduleRefresh(for: controller)
    }

    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
        inlineSuggestionManager?.handleSelectionChange()
        vimCursorManager?.updatePosition()
        statementRunController.refreshHighlight(in: controller)

        // A find match is centred rather than nudged just far enough into view, so the next and previous matches
        // land in the same place instead of hugging whichever edge they came from. The editor's own
        // `scrollSelectionToVisible` deliberately scrolls the minimum distance, which is right when the user is
        // extending a selection and wrong when they are stepping through matches.
        guard !isEditorFirstResponder else { return }
        guard let range = newPositions.first?.range, range.location != NSNotFound else { return }

        // Defer to next run loop to let EmphasisManager finish its work first.
        Task { [weak controller] in
            controller?.textView.scrollToRange(range)
        }
    }

    // Called from the editor's single key-down chain. The key bindings mode goes first, at most one of Vim and Emacs
    // installed, because a mode change has to beat every editing command; the inline suggestion follows it.
    func textViewShouldClaimKeyDown(controller: TextViewController, event: NSEvent) -> NSEvent? {
        if let interceptor = vimKeyInterceptor, interceptor.handleKeyDown(event) == nil { return nil }
        if let interceptor = emacsKeyInterceptor, interceptor.handleKeyDown(event) == nil { return nil }
        if inlineSuggestionManager?.consumesKeyDown(event) == true { return nil }
        return event
    }

    func textViewDidChangeHoveredFold(controller: TextViewController, hit: CollapsedFoldHit?) {
        foldPreview.hoverDidChange(to: hit)
    }

    func destroy() {
        didDestroy = true
        focusClaimPending = false

        removeVimKeyInterceptor()
        removeEmacsKeyInterceptor()

        copilotDocumentSync?.detach()

        foldPreview.destroy()
        inlineSuggestionManager?.uninstall()
        inlineSuggestionManager = nil
        copilotDocumentSync = nil
        copilotInlineSource = nil
        aiChatInlineSource = nil
        appleIntelligenceInlineSource = nil

        // Release closure captures to break potential retain cycles
        releaseWindowSentinel()
        onCloseTab = nil
        onExecuteQuery = nil
        onSelectTab = nil
        onSelectAdjacentTab = nil
        tabCount = nil
        onRunStatement = nil
        statementRunController.onRun = nil
        statementRunController.clear(in: controller)
        diagnosticsController.clear(in: controller)
        currentAIAvailability = nil
        onAIAction = nil
        onSaveAsFavorite = nil
        onShareQuery = nil
        schemaProvider = nil
        controller?.textView?.menu = nil
        contextMenu = nil
        vimEngine = nil
        vimCursorManager = nil

        EditorEventRouter.shared.unregister(self)
        Self.logger.debug("SQLEditorCoordinator destroyed")
        cleanupMonitors()
    }

    private func installFoldPreview(controller: TextViewController) {
        foldPreview.language = PluginManager.shared
            .editorLanguage(for: databaseType ?? .mysql)
            .treeSitterLanguage
        foldPreview.install(controller: controller)
    }

    private func installStatementRunControls(controller: TextViewController) {
        statementRunController.grammar = lexicalGrammar
        statementRunController.statementModel = QueryStatementModel.forDatabaseType(databaseType ?? .mysql)
        statementRunController.isHighlightEnabled = AppSettingsManager.shared.editor.highlightCurrentStatement
        statementRunController.onRun = { [weak self] sql, offset in
            self?.onRunStatement?(sql, offset) ?? false
        }
        statementRunController.install(on: controller)
    }

    func setSessionGrammar(_ grammar: SQLLexicalGrammar) {
        guard grammar != sessionGrammar else { return }
        sessionGrammar = grammar
        guard hasInstalledEditorServices, !isDestroyed, let controller else { return }
        statementRunController.grammar = grammar
        statementRunController.refreshControls(in: controller)
        statementRunController.refreshHighlight(in: controller)
        diagnosticsController.configure(databaseType: databaseType, grammar: grammar)
        refreshDiagnostics(
            in: controller,
            isLargeDocument: controller.textView.textStorage.length > Self.languageServiceLengthLimit
        )
    }

    // A tab runs one query at a time.
    func setStatementRunControlsEnabled(_ isEnabled: Bool) {
        statementRunController.setEnabled(isEnabled, in: controller)
    }

    // Turning the band off also stops resolving the caret's statement for it.
    func setStatementHighlightEnabled(_ isEnabled: Bool) {
        guard statementRunController.isHighlightEnabled != isEnabled else { return }
        statementRunController.isHighlightEnabled = isEnabled
        statementRunController.refreshHighlight(in: controller)
    }

    func moveCursorToStatement(_ direction: StatementNavigationDirection) {
        statementRunController.moveCursor(direction, in: controller)
    }

    // Nil unless this editor holds exactly `text` and splits it the way the caller does, so the answer is a fresh scan's.
    func indexedStatement(
        at cursor: Int,
        in text: String,
        model: QueryStatementModel,
        grammar: SQLLexicalGrammar
    ) -> SQLStatementScanner.LocatedStatement? {
        guard hasInstalledEditorServices, !isDestroyed,
              statementRunController.statementModel == model, statementRunController.grammar == grammar,
              let storage = controller?.textView?.textStorage else {
            return nil
        }
        let snapshot = storage.string
        guard (snapshot as NSString).isEqual(to: text) else { return nil }
        return statementRunController.statement(at: cursor, in: snapshot, storage: storage)
    }

    func maintainedStatement(at offset: Int, in text: String, storage: NSTextStorage) -> QueryStatementHint? {
        guard hasInstalledEditorServices, !isDestroyed,
              storage === controller?.textView?.textStorage,
              let found = statementRunController.maintainedStatement(at: offset, in: text, storage: storage) else {
            return nil
        }
        return QueryStatementHint(range: found.statement.range, grammar: found.grammar)
    }

    // Matched against the text this editor shows, which the tab's binding can lag; an edited-away statement resolves to nothing.
    @discardableResult
    func jumpToStatement(_ anchor: StatementAnchor) -> Bool {
        guard let controller, let textView = controller.textView else { return false }
        guard let range = anchor.resolve(
            in: textView.string,
            model: statementRunController.statementModel,
            grammar: statementRunController.grammar
        ) else {
            return false
        }
        controller.moveCursor(to: range.location)
        return true
    }

    // Reading and running through this one editor keeps one connection's statement out of another connection's database.
    func runStatementAtCursorAndAdvance() {
        guard let statement = statementRunController.statementAtCursor(in: controller),
              let run = onRunStatement else {
            return
        }

        guard run(statement.sql, statement.offset) else { return }
        moveCursorToStatement(.next)
    }

    private func installAIContextMenu(controller: TextViewController) {
        guard controller.textView != nil else { return }
        let menu = AIEditorContextMenu(title: "")
        menu.fullText = { [weak controller] in
            controller?.textView?.string
        }
        menu.selection = { [weak controller] in
            Self.contextSelection(of: controller?.textView)
        }
        menu.aiAvailability = { [weak self] in self?.currentAIAvailability?() ?? .hidden }
        menu.onAIAction = { [weak self, weak controller] action in
            self?.onAIAction?(action, Self.aiTarget(for: controller?.textView))
        }
        menu.onSaveAsFavorite = { [weak self] text in self?.onSaveAsFavorite?(text) }
        menu.onShareQuery = { [weak self] text in self?.onShareQuery?(text) }
        menu.onFormatSQL = { [weak self] range in self?.formatSQL(selectedRange: range) }
        menu.canFormatSQL = { [weak self] in QueryFormatterFactory.supportsFormatting(self?.databaseType) }
        menu.foldStateAtCursor = { [weak controller] in controller?.foldStateAtCursor() }
        menu.onToggleFold = { [weak controller] in controller?.toggleFoldAtCursor() }
        contextMenu = menu
        controller.textView?.menu = menu
    }

    static func aiTarget(for textView: TextView?) -> AIQueryTarget {
        guard let textView else { return .selectionOrStatementAtCursor }
        return .contextMenu(selectedRange: textView.selectedRange(), contextClickWord: textView.contextClickWordRange)
    }

    static func contextSelection(of textView: TextView?) -> EditorContextSelection {
        guard let textView else {
            return EditorContextSelection(selectedRange: NSRange(location: 0, length: 0), contextClickWord: nil)
        }
        return EditorContextSelection(
            selectedRange: textView.selectedRange(),
            contextClickWord: textView.contextClickWordRange
        )
    }

    private let foldPreview = FoldPreviewController()

    func toggleFoldAtCursor() {
        controller?.toggleFoldAtCursor()
    }

    func foldAll() {
        controller?.foldAll()
    }

    func unfoldAll() {
        controller?.unfoldAll()
    }

    // nil when the cursor is not inside a fold.
    func foldStateAtCursor() -> Bool? {
        controller?.foldStateAtCursor()
    }

    func performFormatSQL() {
        guard let textView = controller?.textView else { return }
        formatSQL(selectedRange: textView.selectedRange())
    }

    private func formatSQL(selectedRange: NSRange) {
        guard let textView = controller?.textView else { return }
        let formatter: QueryFormatting
        do {
            guard let made = try QueryFormatterFactory.make(
                for: databaseType,
                sourceFileURL: sourceFileURL,
                grammar: formatGrammar
            ) else { return }
            formatter = made
        } catch {
            Self.logger.error("Formatter rules unreadable: \(error.publicLogShape, privacy: .public)")
            showFormatError(error, in: textView.window)
            return
        }
        let scope = FormatScopeResolver.resolve(
            fullText: textView.string,
            selectedRange: selectedRange
        )

        do {
            let result = try formatter.format(scope.sql, cursorOffset: scope.cursorOffset)
            let replacement = scope.isSelection
                ? FormatScopeResolver.reapplyBoundaryWhitespace(from: scope.sql, to: result.text)
                : result.text
            textView.replaceCharacters(in: scope.range, with: replacement)
            let replacementLength = (replacement as NSString).length
            let caretLocation: Int
            if let newOffset = result.cursorOffset {
                caretLocation = scope.range.location + min(newOffset, replacementLength)
            } else {
                caretLocation = scope.range.location + replacementLength
            }
            controller?.setCursorPositions([CursorPosition(range: NSRange(location: caretLocation, length: 0))])
        } catch {
            Self.logger.error("SQL Formatting error: \(error.publicLogShape, privacy: .public)")
            showFormatError(error, in: textView.window)
        }
    }

    private var formatGrammar: SQLLexicalGrammar? {
        guard let databaseType else { return nil }
        guard let connectionId else { return databaseType.lexicalGrammar }
        return SQLLexicalResolver.executionGrammar(for: databaseType, connectionId: connectionId)
    }

    private func showFormatError(_ error: Error, in window: NSWindow?) {
        AlertHelper.showErrorSheet(
            title: String(localized: "Couldn't Format Query"),
            message: error.localizedDescription,
            window: window
        )
    }

    private func installInlineSuggestionManager(controller: TextViewController) {
        let manager = InlineSuggestionManager()
        manager.install(controller: controller, sourceResolver: { [weak self] in
            self?.resolveInlineSource()
        })
        inlineSuggestionManager = manager
    }

    private var resolvedInlineSourceKind: InlineSuggestionSourceKind {
        InlineSuggestionSourceKind.resolve(
            settings: AppSettingsManager.shared.ai,
            accessAllowed: inlineAccessGate.allowsUnpromptedAccess(to: connectionId)
        )
    }

    private func resolveInlineSource() -> InlineSuggestionSource? {
        let kind = resolvedInlineSourceKind
        if kind != lastInlineSourceKind {
            teardownInlineSources(except: kind)
            lastInlineSourceKind = kind
        }
        switch kind {
        case .off:
            return nil
        case .copilot:
            if copilotInlineSource == nil {
                installCopilotInlineSource()
            }
            return copilotInlineSource
        case .chatCompletion:
            if aiChatInlineSource == nil {
                aiChatInlineSource = AIChatInlineSource(
                    schemaProvider: schemaProvider,
                    connectionId: connectionId,
                    accessGate: inlineAccessGate
                )
            }
            aiChatInlineSource?.schemaProvider = schemaProvider
            aiChatInlineSource?.connectionId = connectionId
            return aiChatInlineSource
        case .appleIntelligence:
            if appleIntelligenceInlineSource == nil {
                appleIntelligenceInlineSource = AppleIntelligenceInlineSource(
                    schemaProvider: schemaProvider,
                    connectionId: connectionId,
                    accessGate: inlineAccessGate
                )
            }
            appleIntelligenceInlineSource?.schemaProvider = schemaProvider
            appleIntelligenceInlineSource?.connectionId = connectionId
            return appleIntelligenceInlineSource
        }
    }

    private func installCopilotInlineSource() {
        let sync = CopilotDocumentSync(server: LiveCopilotDocumentServer(), lengthLimit: Self.languageServiceLengthLimit)
        copilotDocumentSync = sync
        copilotInlineSource = CopilotInlineSource(documentSync: sync)

        let referenceText: String?
        if let textView = controller?.textView, textView.textStorage.length <= Self.languageServiceLengthLimit {
            referenceText = textView.string
        } else {
            referenceText = nil
        }
        let source = copilotSchemaSource()

        Task { [weak self] in
            if let source {
                await sync.preambleBuilder.buildPreamble(
                    schemaProvider: source.schemaProvider,
                    databaseName: source.databaseName,
                    databaseType: source.databaseType,
                    referencing: referenceText,
                    grammar: source.grammar,
                    maxTables: source.budget
                )
            }
            guard let self, self.copilotDocumentSync === sync, self.resolvedInlineSourceKind == .copilot else {
                return
            }
            await CopilotService.shared.start()
            guard self.copilotDocumentSync === sync, let textView = self.controller?.textView else { return }
            sync.attach(
                to: textView,
                tabID: { [weak self] in self?.tabID },
                isAllowed: { [weak self] in self?.resolvedInlineSourceKind == .copilot },
                schemaSource: { [weak self] in self?.copilotSchemaSource() }
            )
        }
    }

    private func copilotSchemaSource() -> CopilotPreambleBuilder.Source? {
        guard let schemaProvider, let databaseType else { return nil }
        let scopeDatabase = databaseScope.flatMap { $0.isServerScoped ? nil : $0.database }
        let databaseName = scopeDatabase ?? connectionId.flatMap {
            DatabaseManager.shared.session(for: $0)?.resolvedBrowseDatabase
        } ?? "database"
        return CopilotPreambleBuilder.Source(
            schemaProvider: schemaProvider,
            databaseName: databaseName,
            databaseType: databaseType,
            grammar: lexicalGrammar,
            budget: AppSettingsManager.shared.ai.clampedMaxSchemaTables
        )
    }

    private func teardownInlineSources(except kind: InlineSuggestionSourceKind) {
        if kind != .copilot {
            copilotDocumentSync?.detach()
            copilotDocumentSync = nil
            copilotInlineSource = nil
        }
        if kind != .chatCompletion {
            aiChatInlineSource = nil
        }
        if kind != .appleIntelligence {
            appleIntelligenceInlineSource = nil
        }
    }

    private func applyKeyBindings(controller: TextViewController) {
        let keyBindings = AppSettingsManager.shared.editor.keyBindings
        if keyBindings != .vim, vimKeyInterceptor != nil {
            uninstallVimKeyInterceptor()
        }
        if keyBindings != .emacs {
            removeEmacsKeyInterceptor()
        }
        if keyBindings == .vim, vimKeyInterceptor == nil {
            installVimKeyInterceptor(controller: controller)
        }
        if keyBindings == .emacs, emacsKeyInterceptor == nil {
            let interceptor = EmacsKeyInterceptor(inlineSuggestionManager: inlineSuggestionManager)
            interceptor.install(controller: controller)
            emacsKeyInterceptor = interceptor
        }
    }

    private func removeEmacsKeyInterceptor() {
        emacsKeyInterceptor?.uninstall()
        emacsKeyInterceptor = nil
    }

    private func installVimKeyInterceptor(controller: TextViewController) {
        guard let textView = controller.textView else { return }

        let adapter = VimTextBufferAdapter(textView: textView)
        let engine = VimEngine(buffer: adapter)

        engine.onModeChange = { [weak self] mode in
            self?.vimMode = mode
            self?.vimCursorManager?.updateMode(mode)
        }

        commandHandler.onExecuteQuery = { [weak self] in
            self?.onExecuteQuery?()
        }
        commandHandler.onCloseTab = { [weak self] in
            self?.onCloseTab?()
        }
        commandHandler.onSelectTab = { [weak self] number in
            self?.onSelectTab?(number)
        }
        commandHandler.onSelectAdjacentTab = { [weak self] offset in
            self?.onSelectAdjacentTab?(offset)
        }
        commandHandler.tabCount = { [weak self] in
            self?.tabCount?() ?? 0
        }
        engine.onCommand = { [weak self] command in
            self?.commandHandler.handle(command)
        }

        let interceptor = VimKeyInterceptor(engine: engine, inlineSuggestionManager: inlineSuggestionManager)
        interceptor.install(controller: controller)

        if let marks = pendingVimDocumentMarks {
            engine.restoreDocumentMarks(marks)
            pendingVimDocumentMarks = nil
        }
        self.vimEngine = engine
        self.vimKeyInterceptor = interceptor
        self.vimMode = .normal

        // Install block cursor for Normal mode
        let cursorManager = VimCursorManager()
        cursorManager.install(textView: textView)
        self.vimCursorManager = cursorManager
    }

    private func uninstallVimKeyInterceptor() {
        removeVimKeyInterceptor()
        vimMode = .normal
    }

    // No @Published write during teardown: it ran inside GraphHost.invalidate() and aborted with an access conflict.
    private func removeVimKeyInterceptor() {
        vimKeyInterceptor?.uninstall()
        vimCursorManager?.uninstall()
        vimCursorManager = nil
        vimKeyInterceptor = nil
        vimEngine = nil
    }

    // The Clear Selection item fires only from a pointer click; returns whether the editor consumed the escape.
    @discardableResult
    func handleEscapeFromMenu() -> Bool {
        let wasFocused = wasEditorFocused
        controller?.dismissCompletions()
        let vimHandled = handleVimEscapeFromMenu()

        if wasFocused {
            reclaimFirstResponder()
        }

        return wasFocused || vimHandled
    }

    private func handleVimEscapeFromMenu() -> Bool {
        vimKeyInterceptor?.handleEscapeFromExternalSource() ?? false
    }

    private func reclaimFirstResponder() {
        guard let controller, let textView = controller.textView, let window = textView.window,
              window.firstResponder !== textView else { return }
        _ = window.makeFirstResponder(textView)
    }

    func checkFirstResponderChange() {
        let focused = isEditorFirstResponder
        guard focused != wasEditorFocused else { return }
        wasEditorFocused = focused

        if focused {
            inlineSuggestionManager?.editorDidFocus()
            vimCursorManager?.resumeBlink()
        } else {
            inlineSuggestionManager?.editorDidBlur()
            vimCursorManager?.pauseBlink()
        }
    }

    private func installEditorSettingsObserver(controller: TextViewController) {
        editorSettingsCancellable = AppEvents.shared.editorSettingsChanged
            .receive(on: RunLoop.main)
            .sink { [weak self, weak controller] _ in
                guard let self, let controller else { return }
                self.applyKeyBindings(controller: controller)
                self.handleInlineProviderChange()
                self.vimCursorManager?.updatePosition()
            }
        aiSettingsCancellable = AppEvents.shared.aiSettingsChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleInlineProviderChange()
            }
        connectionAccessCancellable = AppEvents.shared.connectionUpdated
            .map { _ in () }
            .merge(with: AppEvents.shared.connectionStatusChanged.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleInlineProviderChange()
            }
    }

    private func handleInlineProviderChange() {
        let kind = resolvedInlineSourceKind
        guard kind != lastInlineSourceKind else { return }
        teardownInlineSources(except: kind)
        lastInlineSourceKind = kind
    }

    // Only the two absolute SQLKeywordCase values rewrite typed text, so matchTyped never flips an accepted completion.
    private func uppercaseKeywordIfNeeded(textView: TextView, range: NSRange, string: String) {
        let keywordCase = AppSettingsManager.shared.editor.keywordCase
        guard !isUppercasing,
              keywordCase.rewritesTypedText,
              KeywordUppercaseHelper.isWordBoundary(string),
              PluginManager.shared.editorLanguage(for: databaseType ?? .mysql) == .sql,
              (textView.textStorage.string as NSString).length < 500_000 else { return }

        let nsText = textView.textStorage.string as NSString
        guard let match = KeywordUppercaseHelper.keywordBeforePosition(
            nsText,
            at: range.location,
            uppercase: keywordCase.prefersUppercase,
            grammar: lexicalGrammar
        ) else { return }

        let word = match.word
        let wordRange = match.range
        let uppercased = match.folded

        isUppercasing = true
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self, let textView, !self.didDestroy else {
                self?.isUppercasing = false
                return
            }
            guard wordRange.upperBound <= textView.textStorage.length else {
                self.isUppercasing = false
                return
            }
            let currentWord = (textView.textStorage.string as NSString).substring(with: wordRange)
            guard currentWord == word else {
                self.isUppercasing = false
                return
            }
            // Routed through the text view so the edit reaches the undo manager, the
            // delegate, and the notification that syncs the SwiftUI binding. Writing to
            // textStorage directly left the binding holding the pre-uppercase text.
            textView.replaceCharacters(in: wordRange, with: uppercased)
            self.isUppercasing = false
        }
    }

    func showFindPanel() {
        controller?.showFindPanel()
    }

    func showFindAndReplacePanel() {
        controller?.showFindAndReplacePanel()
    }

    func findNext() {
        controller?.findNext()
    }

    func findPrevious() {
        controller?.findPrevious()
    }

    var hasSelectionForFind: Bool {
        controller?.hasSelectionForFind ?? false
    }

    func useSelectionForFind() {
        controller?.useSelectionForFind()
    }
}
