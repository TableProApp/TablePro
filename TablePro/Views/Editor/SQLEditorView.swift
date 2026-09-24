//
//  SQLEditorView.swift
//  TablePro
//
//  SwiftUI wrapper for TableProEditorKit-based SQL editor
//

import AppKit
import Combine
import SwiftUI
import TableProEditorKit
import TableProGrammars
import TableProPluginKit
import TableProTextEngine

// MARK: - SQLEditorView

/// SwiftUI SQL editor powered by TableProEditorKit
struct SQLEditorView: View {
    @ObservedObject private var settingsManager = AppSettingsManager.shared
    @ObservedObject private var themeEngine = ThemeEngine.shared
    @Binding var text: String
    @Binding var cursorPositions: [CursorPosition]
    @State private var completionProfile: QueryCompletionProfile?
    @State private var observedProfileRevision = 0
    var schemaProvider: SQLSchemaProvider?
    var databaseType: DatabaseType?
    var databaseScope: DatabaseScope?
    var connectionId: UUID?
    var tabID: UUID?
    var claimFocusOnAppear: Bool = false
    /// Called once the editor has latched a focus claim. The owner's one-shot intent is cleared
    /// here rather than on its own `onAppear`, which fires before this subtree renders.
    var onFocusClaimed: (() -> Void)?
    var restoredCursorRange: NSRange?
    var pendingStatementJump: StatementAnchor?
    var onStatementJumpHandled: (() -> Void)?
    var restoredFoldRanges: [Range<Int>]?
    var onFoldRangesChanged: (([Range<Int>]) -> Void)?
    @Binding var vimMode: VimMode
    var onCloseTab: (() -> Void)?
    var onExecuteQuery: (() -> Void)?
    var onRunStatement: ((String, Int) -> Bool)?
    /// A tab runs one thing at a time, so the gutter's run controls go dim for the length of a query.
    var isExecuting: Bool = false
    var currentAIAvailability: (() -> AIQueryActionAvailability)?
    var onAIAction: ((AIQueryAction, AIQueryTarget) -> Void)?
    var onSaveAsFavorite: ((String) -> Void)?

    @State private var editorState = SourceEditorState()
    @State private var completionAdapter = QueryCompletionAdapter(schemaProvider: nil, databaseType: nil)
    @StateObject private var coordinator = SQLEditorCoordinator()
    @State private var editorConfiguration = makeConfiguration()
    @State private var favoritesCancellables: Set<AnyCancellable> = []
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Keep callbacks fresh on every parent re-render
        coordinator.onCloseTab = onCloseTab
        coordinator.onExecuteQuery = onExecuteQuery
        coordinator.onRunStatement = onRunStatement
        coordinator.setStatementRunControlsEnabled(!isExecuting)
        coordinator.setStatementHighlightEnabled(settingsManager.editor.highlightCurrentStatement)
        coordinator.currentAIAvailability = currentAIAvailability
        coordinator.onAIAction = onAIAction
        coordinator.onSaveAsFavorite = onSaveAsFavorite
        coordinator.schemaProvider = schemaProvider
        coordinator.databaseType = databaseType
        coordinator.tabID = tabID
        coordinator.connectionId = connectionId
        if claimFocusOnAppear {
            coordinator.scheduleEditorFocusClaim()
            onFocusClaimed?()
        }
        if let restoredCursorRange {
            coordinator.scheduleCursorRestore(restoredCursorRange)
        }
        if let restoredFoldRanges {
            coordinator.scheduleFoldRestore(restoredFoldRanges)
        }

        return SourceEditor(
            $text,
            language: PluginManager.shared.editorLanguage(for: databaseType ?? .mysql).treeSitterLanguage,
            configuration: editorConfiguration,
            state: $editorState,
            foldProvider: FoldProviderResolver.provider(for: databaseType ?? .mysql),
            coordinators: [coordinator],
            completionDelegate: completionAdapter
        )
        .accessibilityLabel(String(localized: "SQL query editor"))
        .accessibilityIdentifier("sql-editor-textview")
        /// Applied on change rather than while building the view: this is an event, and an editor that is already
        /// mounted never rebuilds from scratch to notice a new value. Cleared whether or not the statement was still
        /// there, so a request that cannot be honoured does not sit pending and block the next one.
        .onChange(of: pendingStatementJump) { newValue in
            guard let newValue else { return }
            coordinator.jumpToStatement(newValue)
            onStatementJumpHandled?()
        }
        .onChange(of: editorState.cursorPositions) { newValue in
            guard let positions = newValue else { return }
            // Skip cursor propagation when the editor doesn't have focus
            // (e.g., find panel match highlighting). Propagating triggers
            // a SwiftUI re-render that disrupts the find panel's focus.
            guard coordinator.isEditorFirstResponder else { return }
            // Guard against stale propagation during tab switch (.id() recreation):
            // verify the editor's text still matches the binding before propagating.
            // Use O(1) length pre-check to avoid O(n) string comparison on large docs.
            if let controller = coordinator.controller {
                let currentString = controller.textView.string as NSString
                let bindingString = text as NSString
                if currentString.length != bindingString.length {
                    return
                }
            }
            cursorPositions = positions
        }
        .onChange(of: editorState.collapsedFoldRanges) { newValue in
            onFoldRangesChanged?(newValue ?? [])
        }
        .onChange(of: tabID) { _ in
            coordinator.repointFolds(to: restoredFoldRanges)
        }
        .onChange(of: connectionId) { _ in
            configureCompletion()
            setupFavoritesObserver()
        }
        /// A tab rebound to another database keeps its view and its connection, so only the scope
        /// moves. Without this the editor keeps completing against the previous database's
        /// provider until the profile resolution returns, which leases a metadata driver and on a
        /// non-poolable engine can queue behind a running query.
        .onChange(of: databaseScope) { _ in
            completionProfile = nil
            configureCompletion()
        }
        .onReceive(completionRevisionChanges) { revision in
            observedProfileRevision = revision
        }
        .task(id: completionProfileRequest) {
            await resolveCompletionProfile()
        }
        .onChange(of: colorScheme) { _ in
            editorConfiguration = Self.makeConfiguration()
        }
        .onChange(of: settingsManager.editor) { _ in
            editorConfiguration = Self.makeConfiguration()
        }
        .onReceive(AppEvents.shared.accessibilityTextSizeChanged) { _ in
            editorConfiguration = Self.makeConfiguration()
        }
        .onReceive(AppEvents.shared.themeChanged) { _ in
            editorConfiguration = Self.makeConfiguration()
        }
        .onAppear {
            initializeEditor()
        }
        .onDisappear {
            teardownFavoritesObserver()
        }
        .onChange(of: coordinator.vimMode) { newMode in
            vimMode = newMode
        }
    }

    // MARK: - Initialization

    private func initializeEditor() {
        configureCompletion()
        setupFavoritesObserver()
    }

    /// The one place the completion service is configured. Appear and the connection change used
    /// to configure without a profile, so whichever of them ran after the resolver silently put
    /// the editor back on the app's own dialect, with nothing scheduled to correct it: the
    /// resolving `.task` re-runs only when its request identity changes.
    private func configureCompletion() {
        completionAdapter.configure(
            schemaProvider: schemaProvider,
            databaseType: databaseType,
            profile: completionProfile
        )
    }

    /// This scope's box alone, never the registry. The registry publishes on every fetch, and an
    /// editor redrawn for each of them would redraw while the user types. A `@Published` publisher
    /// delivers its current value on subscribe, so the key starts in step with the box.
    private var completionRevisionChanges: AnyPublisher<Int, Never> {
        guard let databaseScope else { return Empty().eraseToAnyPublisher() }
        return QueryCompletionProfileRegistry.shared.revisionBox(for: databaseScope).$revision
            .eraseToAnyPublisher()
    }

    /// The revision is part of the key, so an invalidation of this scope restarts the resolution.
    /// It is the value `completionRevisionChanges` last delivered, not a read of the box: the box is
    /// an `ObservableObject`, and reading it from a body subscribes nothing.
    private var completionProfileRequest: CompletionProfileRequest? {
        guard let databaseScope, let databaseType else { return nil }
        return CompletionProfileRequest(
            scope: databaseScope,
            databaseType: databaseType,
            profileRevision: observedProfileRevision
        )
    }

    private func resolveCompletionProfile() async {
        guard let request = completionProfileRequest else { return }
        let profile = await QueryCompletionProfileRegistry.shared.profile(
            for: request.scope,
            databaseType: request.databaseType
        )
        guard !Task.isCancelled else { return }
        completionProfile = profile
        configureCompletion()
    }

    // MARK: - Favorites

    private func setupFavoritesObserver() {
        teardownFavoritesObserver()
        refreshFavoriteKeywords()
        let adapter = completionAdapter
        let connId = connectionId
        let refresh: () -> Void = {
            Task { @MainActor in
                let keywords = await SQLFavoriteManager.shared.fetchKeywordMap(connectionId: connId)
                adapter.updateFavoriteKeywords(keywords)
            }
        }
        AppEvents.shared.sqlFavoritesDidUpdate
            .receive(on: RunLoop.main)
            .sink { payload in
                guard payload == nil || payload == connectionId else { return }
                refresh()
            }
            .store(in: &favoritesCancellables)
        AppEvents.shared.linkedSQLFoldersDidUpdate
            .receive(on: RunLoop.main)
            .sink { payload in
                guard payload == nil || payload == connectionId else { return }
                refresh()
            }
            .store(in: &favoritesCancellables)
    }

    private func refreshFavoriteKeywords() {
        let connId = connectionId
        Task { @MainActor in
            let keywords = await SQLFavoriteManager.shared.fetchKeywordMap(connectionId: connId)
            completionAdapter.updateFavoriteKeywords(keywords)
        }
    }

    private func teardownFavoritesObserver() {
        favoritesCancellables.removeAll()
    }

    // MARK: - Configuration

    private static func makeConfiguration() -> SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: TableProEditorTheme.make(),
                font: ThemeEngine.shared.editorFonts.font,
                wrapLines: ThemeEngine.shared.wordWrap,
                tabWidth: ThemeEngine.shared.tabWidth
            ),
            behavior: .init(
                indentOption: .spaces(count: ThemeEngine.shared.tabWidth)
            ),
            layout: .init(
                contentInsets: NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
            ),
            peripherals: EditorPeripherals.editor(
                lineNumbers: ThemeEngine.shared.showLineNumbers,
                folding: AppSettingsManager.shared.editor.codeFoldingEnabled,
                statementRunControls: AppSettingsManager.shared.editor.showStatementRunControls,
                invisibleCharacters: AppSettingsManager.shared.editor.showInvisibleCharacters
            )
        )
    }
}

private struct CompletionProfileRequest: Hashable {
    let scope: DatabaseScope
    let databaseType: DatabaseType
    let profileRevision: Int
}

// MARK: - Preview

#Preview {
    SQLEditorView(
        text: .constant("SELECT * FROM users\nWHERE active = true;"),
        cursorPositions: .constant([]),
        databaseType: .mysql,
        vimMode: .constant(.normal)
    )
    .frame(width: 500, height: 200)
}
