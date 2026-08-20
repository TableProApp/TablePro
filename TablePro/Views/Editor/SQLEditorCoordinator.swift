//
//  SQLEditorCoordinator.swift
//  TablePro
//
//  TextViewCoordinator for the CodeEditSourceEditor-based SQL editor.
//  Handles find panel workarounds and horizontal scrolling fix.
//

import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import Combine
import Observation
import os
import TableProPluginKit

/// Coordinator for the SQL editor — manages find panel, horizontal scrolling, and scroll-to-match
@Observable
@MainActor
final class SQLEditorCoordinator: TextViewCoordinator, TextViewDelegate {
    // MARK: - Properties

    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLEditorCoordinator")

    /// Above this document length inline AI features are suspended, at the same cutoff where syntax highlighting stops,
    /// so a large document does not copy its whole contents to the assistant on every keystroke.
    private static let languageServiceLengthLimit = EditorHighlighting.maxHighlightableCharacters

    @ObservationIgnored weak var controller: TextViewController?
    @ObservationIgnored private lazy var diagnosticsController = QueryDiagnosticsController(
        databaseType: databaseType
    )
    @ObservationIgnored private let statementRunController = StatementRunController()
    /// Shared schema provider for inline AI suggestions (avoids duplicate schema fetches)
    @ObservationIgnored var schemaProvider: SQLSchemaProvider?
    /// Connection-level AI policy for inline suggestions
    @ObservationIgnored var connectionAIPolicy: AIConnectionPolicy?
    @ObservationIgnored private var contextMenu: AIEditorContextMenu?
    @ObservationIgnored private var inlineSuggestionManager: InlineSuggestionManager?
    @ObservationIgnored private var aiChatInlineSource: AIChatInlineSource?
    @ObservationIgnored private var copilotDocumentSync: CopilotDocumentSync?
    @ObservationIgnored private var copilotInlineSource: CopilotInlineSource?
    @ObservationIgnored private var editorSettingsCancellable: AnyCancellable?
    @ObservationIgnored private var aiSettingsCancellable: AnyCancellable?
    @ObservationIgnored private var lastInlineSourceKind: InlineSourceKind = .off
    /// Debounce work item for frame-change notification to avoid
    /// triggering syntax highlight viewport recalculation on every keystroke.
    @ObservationIgnored private var frameChangeTask: Task<Void, Never>?
    @ObservationIgnored private var isUppercasing = false
    @ObservationIgnored private var wasEditorFocused = false
    @ObservationIgnored private var didDestroy = false
    @ObservationIgnored private var focusClaimPending = false

    /// One way. `destroy()` runs when the editor is dismantled, which it never comes back from.
    var isDestroyed: Bool { didDestroy }

    @ObservationIgnored private var hasInstalledEditorServices = false
    @ObservationIgnored private weak var windowSentinel: WindowAccessorView?

    @ObservationIgnored private var cursorRestorePending: NSRange?

    var pendingFocusClaim: Bool { focusClaimPending }

    var pendingCursorRestore: NSRange? { cursorRestorePending }

    func scheduleEditorFocusClaim() {
        focusClaimPending = true
    }

    /// Latches a saved selection to apply once, the moment the editor is in a window.
    ///
    /// The caller sets this from `body`, which runs many times before the text view exists, so the
    /// setter is idempotent and the value is consumed exactly once in `installEditorServices`.
    /// Pushing it through the SwiftUI cursor binding instead would fight live typing, because the
    /// binding is written on every selection change the user makes.
    func scheduleCursorRestore(_ range: NSRange) {
        guard !hasInstalledEditorServices else { return }
        cursorRestorePending = range
    }

    @ObservationIgnored private var foldRestorePending: [Range<Int>]?

    /// Collapsed folds are replayed once, the same way the cursor is, because the fold state the editor reports back
    /// is written on every collapse the user makes.
    func scheduleFoldRestore(_ ranges: [Range<Int>]) {
        guard !hasInstalledEditorServices, !ranges.isEmpty else { return }
        foldRestorePending = ranges
    }

    /// Query tabs share one editor, so a tab switch replays the incoming tab's collapsed regions over a document the
    /// editor has just been handed. The outgoing tab's folds are already gone: replacing the document drops them,
    /// which is what keeps this from having to clear anything and from reporting a collapse the reader never made.
    func repointFolds(to ranges: [Range<Int>]?) {
        guard let controller else {
            foldRestorePending = ranges
            return
        }
        statementRunController.refreshControls(in: controller)
        statementRunController.refreshHighlight(in: controller)
        guard let ranges, !ranges.isEmpty else { return }
        controller.restoreCollapsedFolds(ranges)
    }

    /// Vim mode for UI observation
    private(set) var vimMode: VimMode = .normal
    @ObservationIgnored private var vimEngine: VimEngine?
    @ObservationIgnored private var vimKeyInterceptor: VimKeyInterceptor?
    @ObservationIgnored private var commandHandler = VimCommandLineHandler()
    @ObservationIgnored private var vimCursorManager: VimCursorManager?
    @ObservationIgnored var onCloseTab: (() -> Void)?
    @ObservationIgnored var onExecuteQuery: (() -> Void)?
    @ObservationIgnored var onRunStatement: ((String, Int) -> Bool)?
    @ObservationIgnored var onAIExplain: ((String) -> Void)?
    @ObservationIgnored var onAIOptimize: ((String) -> Void)?
    @ObservationIgnored var onSaveAsFavorite: ((String) -> Void)?
    @ObservationIgnored var databaseType: DatabaseType?
    @ObservationIgnored var tabID: UUID?
    @ObservationIgnored var connectionId: UUID?

    /// Whether the editor text view is currently the first responder.
    /// Used to guard cursor propagation — when the find panel highlights
    /// a match it changes the selection programmatically, and propagating
    /// that to SwiftUI triggers a re-render that disrupts the find panel's
    /// @FocusState.
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
        frameChangeTask?.cancel()
        frameChangeTask = nil
    }

    // MARK: - TextViewCoordinator

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
        diagnosticsController.configure(databaseType: databaseType)
        diagnosticsController.scheduleRefresh(for: controller)
        installVimModeIfEnabled(controller: controller)
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

        if !isLargeDocument, !didDestroy, let tabID, let sync = copilotDocumentSync {
            let text = textView.string
            Task { await sync.didChangeText(tabID: tabID, newText: text) }
        }

        frameChangeTask?.cancel()
        frameChangeTask = Task { [weak controller] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let controller, let textView = controller.textView else { return }
            NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: textView)
        }

        uppercaseKeywordIfNeeded(textView: textView, range: range, string: string)
        statementRunController.scheduleControlsRefresh(in: controller)

        if !isLargeDocument {
            diagnosticsController.scheduleRefresh(for: controller)
        }
    }

    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
        inlineSuggestionManager?.handleSelectionChange()
        vimCursorManager?.updatePosition()
        statementRunController.refreshHighlight(in: controller)

        // When the find panel navigates to a match, it changes the selection
        // but the editor is not first responder. Scroll to the match manually
        // because CodeEditTextView's scrollSelectionToVisible() fails for
        // off-screen matches (TextSelection.boundingRect is .zero until drawn).
        guard !isEditorFirstResponder else { return }
        guard let range = newPositions.first?.range, range.location != NSNotFound else { return }

        // Defer to next run loop to let EmphasisManager finish its work first.
        Task { [weak controller] in
            controller?.textView.scrollToRange(range)
        }
    }

    func textViewDidChangeHoveredFold(controller: TextViewController, hit: CollapsedFoldHit?) {
        foldPreview.hoverDidChange(to: hit)
    }

    func destroy() {
        didDestroy = true
        focusClaimPending = false

        uninstallVimKeyInterceptor()

        if let tabID, let sync = copilotDocumentSync {
            let id = tabID
            Task { await sync.didCloseTab(tabID: id) }
        }

        foldPreview.destroy()
        inlineSuggestionManager?.uninstall()
        inlineSuggestionManager = nil
        copilotDocumentSync = nil
        copilotInlineSource = nil
        aiChatInlineSource = nil

        // Release closure captures to break potential retain cycles
        releaseWindowSentinel()
        onCloseTab = nil
        onExecuteQuery = nil
        onRunStatement = nil
        statementRunController.onRun = nil
        statementRunController.clear(in: controller)
        onAIExplain = nil
        onAIOptimize = nil
        onSaveAsFavorite = nil
        schemaProvider = nil
        controller?.textView?.menu = nil
        contextMenu = nil
        vimEngine = nil
        vimCursorManager = nil

        EditorEventRouter.shared.unregister(self)
        Self.logger.debug("SQLEditorCoordinator destroyed")
        cleanupMonitors()
    }

    // MARK: - AI Context Menu

    private func installFoldPreview(controller: TextViewController) {
        foldPreview.language = PluginManager.shared
            .editorLanguage(for: databaseType ?? .mysql)
            .treeSitterLanguage
        foldPreview.install(controller: controller)
    }

    private func installStatementRunControls(controller: TextViewController) {
        statementRunController.dialect = SqlDialect.from(databaseTypeId: (databaseType ?? .mysql).rawValue)
        statementRunController.isHighlightEnabled = AppSettingsManager.shared.editor.highlightCurrentStatement
        statementRunController.onRun = { [weak self] sql, offset in
            self?.onRunStatement?(sql, offset) ?? false
        }
        statementRunController.install(on: controller)
    }

    /// Turns the run controls off for the length of a query, because a tab runs one at a time.
    func setStatementRunControlsEnabled(_ isEnabled: Bool) {
        statementRunController.setEnabled(isEnabled, in: controller)
    }

    /// Follows the Settings toggle, so turning the band off also stops resolving the caret's statement for it.
    func setStatementHighlightEnabled(_ isEnabled: Bool) {
        guard statementRunController.isHighlightEnabled != isEnabled else { return }
        statementRunController.isHighlightEnabled = isEnabled
        statementRunController.refreshHighlight(in: controller)
    }

    /// Moves the caret to the neighbouring statement.
    func moveCursorToStatement(_ direction: StatementNavigationDirection) {
        statementRunController.moveCursor(direction, in: controller)
    }

    /// Takes the reader to the statement a result came from.
    ///
    /// Resolved here rather than by the caller because the anchor has to be matched against the text this editor is
    /// showing, which the tab's binding can lag behind by a keystroke. A statement that has since been edited away
    /// resolves to nothing and the caret stays where it is, which is the right answer: there is nowhere to go.
    ///
    /// Reports whether it moved, so the caller can retire the request either way and a statement that is gone does
    /// not leave one pending forever.
    @discardableResult
    func jumpToStatement(_ anchor: StatementAnchor) -> Bool {
        guard let controller, let textView = controller.textView else { return false }
        guard let range = anchor.resolve(in: textView.string, dialect: statementRunController.dialect) else {
            return false
        }
        controller.moveCursor(to: range.location)
        return true
    }

    /// Runs the statement the caret is in, then moves the caret to the next one.
    ///
    /// Both halves go through this one editor. Reading the SQL here and executing it somewhere else would let the two
    /// name different editors: a window hosts a workspace per connection and their editors all stay registered, so a
    /// command that resolves its text through the window and its execution through the selected workspace can send
    /// one connection's statement to another connection's database. `onRunStatement` is the same callback the gutter
    /// control uses, and the view binds it to the coordinator that owns this editor.
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
        menu.hasSelection = { [weak controller] in
            guard let controller else { return false }
            return controller.cursorPositions.contains { $0.range.length > 0 }
        }
        menu.selectedText = { [weak controller] in
            guard let controller, let textView = controller.textView else { return nil }
            let range = textView.selectedRange()
            guard range.length > 0 else { return nil }
            return (textView.string as NSString).substring(with: range)
        }
        menu.fullText = { [weak controller] in
            controller?.textView?.string
        }
        menu.onExplainWithAI = { [weak self] text in self?.onAIExplain?(text) }
        menu.onOptimizeWithAI = { [weak self] text in self?.onAIOptimize?(text) }
        menu.onSaveAsFavorite = { [weak self] text in self?.onSaveAsFavorite?(text) }
        menu.onFormatSQL = { [weak self] in self?.performFormatSQL() }
        menu.foldStateAtCursor = { [weak controller] in controller?.foldStateAtCursor() }
        menu.onToggleFold = { [weak controller] in controller?.toggleFoldAtCursor() }
        contextMenu = menu
        controller.textView?.menu = menu
    }

    @ObservationIgnored private let foldPreview = FoldPreviewController()

    func toggleFoldAtCursor() {
        controller?.toggleFoldAtCursor()
    }

    func foldAll() {
        controller?.foldAll()
    }

    func unfoldAll() {
        controller?.unfoldAll()
    }

    /// Whether the fold containing the cursor is collapsed. `nil` when the cursor is not inside a fold.
    func foldStateAtCursor() -> Bool? {
        controller?.foldStateAtCursor()
    }

    func performFormatSQL() {
        guard let textView = controller?.textView else { return }
        let formatter = QueryFormatterFactory.make(for: databaseType)
        let scope = FormatScopeResolver.resolve(
            fullText: textView.string,
            selectedRange: textView.selectedRange()
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
            Self.logger.error("SQL Formatting error: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Inline Suggestion Manager

    private func installInlineSuggestionManager(controller: TextViewController) {
        let manager = InlineSuggestionManager()
        manager.install(controller: controller, sourceResolver: { [weak self] in
            self?.resolveInlineSource()
        })
        inlineSuggestionManager = manager
    }

    private enum InlineSourceKind {
        case off
        case copilot
        case ai
    }

    private var resolvedInlineSourceKind: InlineSourceKind {
        let ai = AppSettingsManager.shared.ai
        guard ai.enabled, ai.inlineSuggestionsEnabled, let active = ai.activeProvider else {
            return .off
        }
        return active.type == .copilot ? .copilot : .ai
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
        case .ai:
            if aiChatInlineSource == nil {
                aiChatInlineSource = AIChatInlineSource(
                    schemaProvider: schemaProvider,
                    connectionPolicy: connectionAIPolicy
                )
            }
            return aiChatInlineSource
        }
    }

    private func installCopilotInlineSource() {
        let sync = CopilotDocumentSync()
        copilotDocumentSync = sync
        copilotInlineSource = CopilotInlineSource(documentSync: sync)

        let capturedTabID = tabID
        let capturedText = controller?.textView?.string ?? ""
        let capturedSchemaProvider = schemaProvider
        let capturedDBType = databaseType
        let dbName = connectionId.flatMap {
            DatabaseManager.shared.session(for: $0)?.resolvedBrowseDatabase
        } ?? "database"

        Task {
            if let provider = capturedSchemaProvider, let dbType = capturedDBType {
                await sync.preambleBuilder.buildPreamble(
                    schemaProvider: provider,
                    databaseName: dbName,
                    databaseType: dbType
                )
            }
            if let tabID = capturedTabID {
                sync.ensureDocumentOpen(tabID: tabID, text: capturedText)
                await sync.didActivateTab(tabID: tabID, text: capturedText)
            }
        }
    }

    private func teardownInlineSources(except kind: InlineSourceKind) {
        if kind != .copilot {
            if let tabID, let sync = copilotDocumentSync {
                let id = tabID
                Task { await sync.didCloseTab(tabID: id) }
            }
            copilotDocumentSync = nil
            copilotInlineSource = nil
        }
        if kind != .ai {
            aiChatInlineSource = nil
        }
    }

    // MARK: - Vim Mode

    private func installVimModeIfEnabled(controller: TextViewController) {
        guard AppSettingsManager.shared.editor.vimModeEnabled else { return }
        installVimKeyInterceptor(controller: controller)
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
        engine.onCommand = { [weak self] command in
            self?.commandHandler.handle(command)
        }

        let interceptor = VimKeyInterceptor(engine: engine, inlineSuggestionManager: inlineSuggestionManager)
        interceptor.install(controller: controller)

        self.vimEngine = engine
        self.vimKeyInterceptor = interceptor
        self.vimMode = .normal

        // Install block cursor for Normal mode
        let cursorManager = VimCursorManager()
        cursorManager.install(textView: textView)
        self.vimCursorManager = cursorManager
    }

    private func uninstallVimKeyInterceptor() {
        vimKeyInterceptor?.uninstall()
        vimCursorManager?.uninstall()
        vimCursorManager = nil
        vimKeyInterceptor = nil
        vimEngine = nil
        vimMode = .normal
    }

    private func handleVimSettingsChange(controller: TextViewController) {
        let enabled = AppSettingsManager.shared.editor.vimModeEnabled
        if enabled && vimKeyInterceptor == nil {
            installVimKeyInterceptor(controller: controller)
        } else if !enabled && vimKeyInterceptor != nil {
            uninstallVimKeyInterceptor()
        }
    }

    // MARK: - Menu Escape Routing

    /// Called by `EditorEventRouter.handleEscapeFromMenu()` when the "Clear Selection"
    /// menu item's bare-Escape key equivalent fires. That key equivalent preempts the
    /// editor's local event monitors, so the completion popup, Vim, and first-responder
    /// handling that would normally run on Escape never do. Dismisses an open completion
    /// popup, hands the keystroke to Vim when it is mid-command, and restores first
    /// responder and the caret when this editor was the focused surface. Returns whether
    /// the editor consumed the escape so the menu skips its cancelOperation fallback.
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

    /// Restores editor focus after another view in the same window took it.
    private func reclaimFirstResponder() {
        guard let controller, let textView = controller.textView, let window = textView.window,
              window.firstResponder !== textView else { return }
        _ = window.makeFirstResponder(textView)
    }

    // MARK: - First Responder Tracking

    func checkFirstResponderChange() {
        let focused = isEditorFirstResponder
        guard focused != wasEditorFocused else { return }
        wasEditorFocused = focused

        if focused {
            vimKeyInterceptor?.editorDidFocus()
            inlineSuggestionManager?.editorDidFocus()
            vimCursorManager?.resumeBlink()
        } else {
            vimKeyInterceptor?.editorDidBlur()
            inlineSuggestionManager?.editorDidBlur()
            vimCursorManager?.pauseBlink()
        }
    }

    // MARK: - Editor Settings Observer

    private func installEditorSettingsObserver(controller: TextViewController) {
        editorSettingsCancellable = AppEvents.shared.editorSettingsChanged
            .receive(on: RunLoop.main)
            .sink { [weak self, weak controller] _ in
                guard let self, let controller else { return }
                self.handleVimSettingsChange(controller: controller)
                self.handleInlineProviderChange()
                self.vimCursorManager?.updatePosition()
            }
        aiSettingsCancellable = AppEvents.shared.aiSettingsChanged
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

    // MARK: - Keyword Auto-Uppercase

    private func uppercaseKeywordIfNeeded(textView: TextView, range: NSRange, string: String) {
        guard !isUppercasing,
              AppSettingsManager.shared.editor.uppercaseKeywords,
              KeywordUppercaseHelper.isWordBoundary(string),
              (textView.textStorage.string as NSString).length < 500_000 else { return }

        let nsText = textView.textStorage.string as NSString
        guard let match = KeywordUppercaseHelper.keywordBeforePosition(nsText, at: range.location) else { return }

        let word = match.word
        let wordRange = match.range
        let uppercased = word.uppercased()

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

    // MARK: - Find Panel

    func showFindPanel() {
        controller?.showFindPanel()
    }

    func findNext() {
        controller?.findNext()
    }

    func findPrevious() {
        controller?.findPrevious()
    }
}
