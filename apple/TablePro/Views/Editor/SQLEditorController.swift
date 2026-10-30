//
//  SQLEditorController.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI
import TableProEditorKit
import TableProGrammars
import TableProPluginKit
import TableProSQLGrammar
import TableProTextEngine

/// What a query tab hands the SQL editor on every update.
struct SQLEditorInput {
    var text: Binding<String>
    var cursorPositions: Binding<[CursorPosition]>
    var schemaProvider: SQLSchemaProvider?
    var databaseType: DatabaseType?
    var databaseScope: DatabaseScope?
    var connectionId: UUID?
    var tabID: UUID?
    var sourceFileURL: URL?
    var claimFocusOnAppear = false
    /// Called once the editor has latched a focus claim, so the owner's one-shot intent is cleared.
    var onFocusClaimed: (() -> Void)?
    var restoredCursorRange: NSRange?
    var pendingStatementJump: StatementAnchor?
    var onStatementJumpHandled: (() -> Void)?
    var restoredFoldRanges: [Range<Int>]?
    var onFoldRangesChanged: (([Range<Int>]) -> Void)?
    var onCloseTab: (() -> Void)?
    var onExecuteQuery: (() -> Void)?
    var onSelectTab: ((Int) -> Void)?
    var onSelectAdjacentTab: ((Int) -> Void)?
    var tabCount: (() -> Int)?
    var onRunStatement: ((String, Int) -> Bool)?
    /// A tab runs one thing at a time, so the gutter's run controls go dim for the length of a query.
    var isExecuting = false
    var currentAIAvailability: (() -> AIQueryActionAvailability)?
    var onAIAction: ((AIQueryAction, AIQueryTarget) -> Void)?
    var onSaveAsFavorite: ((String) -> Void)?
}

/// The SQL editor in AppKit, so the query tab hosts it with no SwiftUI host around it: each one above an editor
/// forced the window to lay out every hosting view again as the editor's views went in.
@MainActor
final class SQLEditorController {
    let coordinator = SQLEditorCoordinator()
    /// Reports Vim's mode to whatever draws it beside the editor.
    var onVimModeChange: ((VimMode) -> Void)?

    private let completionAdapter = QueryCompletionAdapter(schemaProvider: nil, databaseType: nil)
    private var host: SourceEditorHost?
    private var input: SQLEditorInput
    private var configuration = SQLEditorController.makeConfiguration()
    private var completionProfile: QueryCompletionProfile?
    private var observedProfileRevision = 0
    private var profileRequest: CompletionProfileRequest?
    private var profileTask: Task<Void, Never>?
    private var revisionSubscription: AnyCancellable?
    private var favoritesCancellables: Set<AnyCancellable> = []
    private var pendingCaret: [CursorPosition]?
    private var cancellables: Set<AnyCancellable> = []
    private var isTornDown = false
    // One instance, because `SourceEditor` keeps the provider it was created with and a new grammar has to reach it.
    private lazy var foldProvider: LineFoldProvider? = FoldProviderResolver.provider(
        for: input.databaseType ?? .mysql,
        grammar: coordinator.lexicalGrammar
    )

    var textViewController: TextViewController {
        guard let host else { preconditionFailure("SQLEditorController used before init finished") }
        return host.controller
    }

    init(input: SQLEditorInput) {
        self.input = input
        applyInput(input)
        let host = SourceEditorHost { state in self.makeEditor(state: state) }
        host.onStateChange = { [weak self] old, new in self?.editorStateDidChange(from: old, to: new) }
        self.host = host

        let view = host.controller.view
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel(String(localized: "SQL query editor"))
        view.setAccessibilityIdentifier("sql-editor-textview")

        observeEditorSettings()
        observeVimMode()
        observeSessionChanges()
        configureCompletion()
        setupFavoritesObserver()
        subscribeToCompletionRevision()
        resolveCompletionProfileIfNeeded()
    }

    func apply(_ newInput: SQLEditorInput) {
        guard !isTornDown else { return }
        let old = input
        input = newInput
        applyInput(newInput)
        pushEditor()

        if newInput.pendingStatementJump != old.pendingStatementJump, let jump = newInput.pendingStatementJump {
            coordinator.jumpToStatement(jump)
            newInput.onStatementJumpHandled?()
        }
        if newInput.tabID != old.tabID {
            pendingCaret = nil
            coordinator.repointFolds(to: newInput.restoredFoldRanges)
        }
        if newInput.connectionId != old.connectionId {
            configureCompletion()
            setupFavoritesObserver()
        }
        /// A tab rebound to another database keeps its editor and its connection, so only the scope moves. Without
        /// this the editor keeps completing against the previous database's provider until the profile resolution
        /// returns, which leases a metadata driver and on a non-poolable engine can queue behind a running query.
        if newInput.databaseScope != old.databaseScope {
            completionProfile = nil
            configureCompletion()
            subscribeToCompletionRevision()
        }
        resolveCompletionProfileIfNeeded()
    }

    /// The editor's terminal teardown, run when its query tab area goes away for good, never when it only leaves
    /// the window.
    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        profileTask?.cancel()
        profileTask = nil
        revisionSubscription = nil
        favoritesCancellables.removeAll()
        cancellables.removeAll()
        host?.dismantle()
    }

    private func applyInput(_ input: SQLEditorInput) {
        coordinator.onCloseTab = input.onCloseTab
        coordinator.onExecuteQuery = input.onExecuteQuery
        coordinator.onSelectTab = input.onSelectTab
        coordinator.onSelectAdjacentTab = input.onSelectAdjacentTab
        coordinator.tabCount = input.tabCount
        coordinator.onRunStatement = input.onRunStatement
        coordinator.setStatementRunControlsEnabled(!input.isExecuting)
        coordinator.setStatementHighlightEnabled(AppSettingsManager.shared.editor.highlightCurrentStatement)
        coordinator.currentAIAvailability = input.currentAIAvailability
        coordinator.onAIAction = input.onAIAction
        coordinator.onSaveAsFavorite = input.onSaveAsFavorite
        coordinator.schemaProvider = input.schemaProvider
        coordinator.databaseType = input.databaseType
        coordinator.tabID = input.tabID
        coordinator.connectionId = input.connectionId
        coordinator.sourceFileURL = input.sourceFileURL
        if input.claimFocusOnAppear {
            coordinator.scheduleEditorFocusClaim()
            input.onFocusClaimed?()
        }
        if let restoredCursorRange = input.restoredCursorRange {
            coordinator.scheduleCursorRestore(restoredCursorRange)
        }
        if let restoredFoldRanges = input.restoredFoldRanges {
            coordinator.scheduleFoldRestore(restoredFoldRanges)
        }
        // Also on every run's start and end, which is when a `SET` can have changed a session flag.
        refreshSessionGrammar()
    }

    /// The grammar the session lexes with: KingbaseES in Oracle mode, MySQL under `NO_BACKSLASH_ESCAPES`, or
    /// PostgreSQL with `standard_conforming_strings` off each split text differently from the engine's default.
    private func refreshSessionGrammar() {
        guard let databaseType = input.databaseType else { return }
        let grammar: SQLLexicalGrammar
        if let scope = input.databaseScope {
            grammar = SQLLexicalResolver.executionGrammar(for: databaseType, scope: scope)
        } else if let connectionId = input.connectionId {
            grammar = SQLLexicalResolver.executionGrammar(for: databaseType, connectionId: connectionId)
        } else {
            grammar = databaseType.lexicalGrammar
        }
        guard grammar != coordinator.sessionGrammar else { return }
        coordinator.setSessionGrammar(grammar)
        (foldProvider as? SQLLineFoldProvider)?.grammar = grammar
        configureCompletion()
    }

    private func observeSessionChanges() {
        AppEvents.shared.connectionStatusChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] change in
                guard let self, !self.isTornDown, change.connectionId == self.input.connectionId else { return }
                self.refreshSessionGrammar()
            }
            .store(in: &cancellables)
    }

    private func makeEditor(state: Binding<SourceEditorState>) -> SourceEditor {
        let databaseType = input.databaseType ?? .mysql
        let text = Binding<String>(
            get: { [weak self] in self?.input.text.wrappedValue ?? "" },
            set: { [weak self] newValue in
                self?.input.text.wrappedValue = newValue
                self?.passPendingCaretOn()
            }
        )
        return SourceEditor(
            text,
            language: PluginManager.shared.editorLanguage(for: databaseType).treeSitterLanguage,
            configuration: configuration,
            state: state,
            foldProvider: foldProvider,
            coordinators: [coordinator],
            completionDelegate: completionAdapter
        )
    }

    private func pushEditor() {
        host?.update { state in self.makeEditor(state: state) }
    }

    private func editorStateDidChange(from old: SourceEditorState, to new: SourceEditorState) {
        if new.cursorPositions != old.cursorPositions, let positions = new.cursorPositions {
            pendingCaret = positions
            passPendingCaretOn()
        }
        if new.collapsedFoldRanges != old.collapsedFoldRanges {
            input.onFoldRangesChanged?(new.collapsedFoldRanges ?? [])
        }
    }

    // An edit reports its caret before its text is written back, so the caret waits for the text; one from a document
    // the binding does not hold, as across a tab switch, is never passed on.
    private func passPendingCaretOn() {
        guard let positions = pendingCaret else { return }
        let editorLength = (textViewController.textView.string as NSString).length
        guard editorLength == (input.text.wrappedValue as NSString).length else { return }
        pendingCaret = nil
        input.cursorPositions.wrappedValue = positions
    }

    // MARK: - Settings

    private func observeEditorSettings() {
        // `$editor` publishes before the value is stored; the theme reads the stored settings too.
        AppSettingsManager.shared.$editor
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] editor in
                guard let self else { return }
                self.coordinator.setStatementHighlightEnabled(editor.highlightCurrentStatement)
                self.reloadConfiguration()
            }
            .store(in: &cancellables)
        AppEvents.shared.accessibilityTextSizeChanged
            .sink { [weak self] _ in self?.reloadConfiguration() }
            .store(in: &cancellables)
        AppEvents.shared.themeChanged
            .sink { [weak self] _ in self?.reloadConfiguration() }
            .store(in: &cancellables)
    }

    private func reloadConfiguration() {
        guard !isTornDown else { return }
        configuration = Self.makeConfiguration()
        pushEditor()
    }

    private func observeVimMode() {
        coordinator.$vimMode
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] mode in self?.onVimModeChange?(mode) }
            .store(in: &cancellables)
    }

    private static func makeConfiguration() -> SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: ThemeEngine.shared.makeEditorTheme(),
                font: ThemeEngine.shared.editorFonts.font,
                wrapLines: AppSettingsManager.shared.editor.wordWrap,
                tabWidth: AppSettingsManager.shared.editor.clampedTabWidth
            ),
            behavior: .init(
                indentOption: .spaces(count: AppSettingsManager.shared.editor.clampedTabWidth)
            ),
            layout: .init(
                contentInsets: NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
            ),
            peripherals: EditorPeripherals.editor(
                lineNumbers: AppSettingsManager.shared.editor.showLineNumbers,
                folding: AppSettingsManager.shared.editor.codeFoldingEnabled,
                statementRunControls: AppSettingsManager.shared.editor.showStatementRunControls,
                invisibleCharacters: AppSettingsManager.shared.editor.showInvisibleCharacters
            )
        )
    }

    // MARK: - Completion

    /// The one place the completion service is configured. Configuring without a profile anywhere else put the
    /// editor back on the app's own dialect after the resolver had run, with nothing scheduled to correct it.
    private func configureCompletion() {
        completionAdapter.configure(
            schemaProvider: input.schemaProvider,
            databaseType: input.databaseType,
            profile: completionProfile,
            connectionId: input.connectionId,
            grammar: coordinator.sessionGrammar
        )
    }

    /// This scope's box alone, never the registry: the registry publishes on every fetch, and resolving again for
    /// each of them would run while the user types. A `@Published` publisher delivers its current value on
    /// subscribe, so the revision starts in step with the box.
    private func subscribeToCompletionRevision() {
        revisionSubscription = nil
        guard let scope = input.databaseScope else { return }
        revisionSubscription = QueryCompletionProfileRegistry.shared.revisionBox(for: scope).$revision
            .sink { [weak self] revision in
                guard let self else { return }
                self.observedProfileRevision = revision
                self.resolveCompletionProfileIfNeeded()
            }
    }

    private var completionProfileRequest: CompletionProfileRequest? {
        guard let databaseScope = input.databaseScope, let databaseType = input.databaseType else { return nil }
        return CompletionProfileRequest(
            scope: databaseScope,
            databaseType: databaseType,
            profileRevision: observedProfileRevision
        )
    }

    /// The revision is part of the request, so an invalidation of this scope restarts the resolution.
    private func resolveCompletionProfileIfNeeded() {
        let request = completionProfileRequest
        guard request != profileRequest, !isTornDown else { return }
        profileRequest = request
        profileTask?.cancel()
        guard let request else {
            profileTask = nil
            return
        }
        profileTask = Task { [weak self] in
            let profile = await QueryCompletionProfileRegistry.shared.profile(
                for: request.scope,
                databaseType: request.databaseType
            )
            guard !Task.isCancelled, let self else { return }
            self.completionProfile = profile
            self.configureCompletion()
        }
    }

    // MARK: - Favorites

    private func setupFavoritesObserver() {
        favoritesCancellables.removeAll()
        refreshFavoriteKeywords()
        let adapter = completionAdapter
        let connId = input.connectionId
        let refresh: () -> Void = {
            Task { @MainActor in
                let keywords = await SQLFavoriteManager.shared.fetchKeywordMap(connectionId: connId)
                adapter.updateFavoriteKeywords(keywords)
            }
        }
        AppEvents.shared.sqlFavoritesDidUpdate
            .receive(on: RunLoop.main)
            .sink { payload in
                guard payload == nil || payload == connId else { return }
                refresh()
            }
            .store(in: &favoritesCancellables)
        AppEvents.shared.linkedSQLFoldersDidUpdate
            .receive(on: RunLoop.main)
            .sink { payload in
                guard payload == nil || payload == connId else { return }
                refresh()
            }
            .store(in: &favoritesCancellables)
    }

    private func refreshFavoriteKeywords() {
        let connId = input.connectionId
        let adapter = completionAdapter
        Task { @MainActor in
            let keywords = await SQLFavoriteManager.shared.fetchKeywordMap(connectionId: connId)
            adapter.updateFavoriteKeywords(keywords)
        }
    }
}

private struct CompletionProfileRequest: Hashable {
    let scope: DatabaseScope
    let databaseType: DatabaseType
    let profileRevision: Int
}
