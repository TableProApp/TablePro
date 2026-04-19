//
//  SQLEditorView.swift
//  TablePro
//
//  SwiftUI wrapper for CodeEditSourceEditor-based SQL editor
//

import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import SwiftUI

// MARK: - SQLEditorView

/// SwiftUI SQL editor powered by CodeEditSourceEditor
struct SQLEditorView: View {
    @Binding var text: String
    @Binding var cursorPositions: [CursorPosition]
    var schemaProvider: SQLSchemaProvider?
    var databaseType: DatabaseType?
    var connectionId: UUID?
    var connectionAIPolicy: AIConnectionPolicy?
    @Binding var vimMode: VimMode
    var onCloseTab: (() -> Void)?
    var onExecuteQuery: (() -> Void)?
    var onAIExplain: ((String) -> Void)?
    var onAIOptimize: ((String) -> Void)?
    var onSaveAsFavorite: ((String) -> Void)?
    var onFormatSQL: (() -> Void)?

    @State private var editorState = SourceEditorState()
    @State private var completionAdapter: SQLCompletionAdapter?
    @State private var coordinator = SQLEditorCoordinator()
    @State private var editorReady = false
    @State private var editorConfiguration = makeConfiguration()
    @State private var favoritesObserver: NSObjectProtocol?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Keep callbacks fresh on every parent re-render
        coordinator.onCloseTab = onCloseTab
        coordinator.onExecuteQuery = onExecuteQuery
        coordinator.onAIExplain = onAIExplain
        coordinator.onAIOptimize = onAIOptimize
        coordinator.onSaveAsFavorite = onSaveAsFavorite
        coordinator.onFormatSQL = onFormatSQL
        coordinator.schemaProvider = schemaProvider
        coordinator.connectionAIPolicy = connectionAIPolicy
        coordinator.databaseType = databaseType

        return Group {
            if editorReady {
            SourceEditor(
                $text,
                language: PluginManager.shared.editorLanguage(for: databaseType ?? .mysql).treeSitterLanguage,
                configuration: editorConfiguration,
                state: $editorState,
                coordinators: [coordinator],
                completionDelegate: completionAdapter
            )
            .onChange(of: editorState.cursorPositions) { _, newValue in
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
            // SourceEditor doesn't re-read the text binding in updateNSViewController,
            // so programmatic changes on the SAME tab (clear, format) won't appear
            // without this. Tab switches don't need it — .id(tab.id) recreates the
            // entire SourceEditor with the correct text.
            .onChange(of: text) { _, newValue in
                if let controller = coordinator.controller {
                    let currentString = controller.textView.string as NSString
                    let newString = newValue as NSString
                    // Fast O(1) length check before expensive O(n) string equality
                    if currentString.length != newString.length || currentString != newString {
                        let fullRange = NSRange(location: 0, length: currentString.length)
                        controller.textView.replaceCharacters(in: fullRange, with: newValue)
                    }
                }
            }
            .onChange(of: connectionId) { _, _ in
                if let schemaProvider, let completionAdapter {
                    completionAdapter.updateSchemaProvider(schemaProvider, databaseType: databaseType)
                }
                setupFavoritesObserver()
            }
            .onChange(of: colorScheme) {
                editorConfiguration = Self.makeConfiguration()
            }
            .onChange(of: AppSettingsManager.shared.editor) {
                editorConfiguration = Self.makeConfiguration()
            }
            .onReceive(NotificationCenter.default.publisher(for: .accessibilityTextSizeDidChange)) { _ in
                editorConfiguration = Self.makeConfiguration()
            }
            .onAppear {
                if coordinator.isDestroyed {
                    coordinator.revive()
                }
                if completionAdapter == nil {
                    completionAdapter = SQLCompletionAdapter(schemaProvider: schemaProvider, databaseType: databaseType)
                }
                setupFavoritesObserver()
            }
        } else {
            Color(nsColor: .textBackgroundColor)
                .onAppear {
                    if coordinator.isDestroyed {
                        coordinator.revive()
                    }
                    if completionAdapter == nil {
                        completionAdapter = SQLCompletionAdapter(schemaProvider: schemaProvider, databaseType: databaseType)
                    }
                    setupFavoritesObserver()
                    editorReady = true
                }
            }
        }
        .onDisappear {
            teardownFavoritesObserver()
            coordinator.destroy()
            completionAdapter = nil
        }
        .onChange(of: coordinator.vimMode) { _, newMode in
            vimMode = newMode
        }
    }

    // MARK: - Favorites

    private func setupFavoritesObserver() {
        teardownFavoritesObserver()
        refreshFavoriteKeywords()
        let adapter = completionAdapter
        let connId = connectionId
        favoritesObserver = NotificationCenter.default.addObserver(
            forName: .sqlFavoritesDidUpdate,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let keywords = await SQLFavoriteManager.shared.fetchKeywordMap(connectionId: connId)
                adapter?.updateFavoriteKeywords(keywords)
            }
        }
    }

    private func refreshFavoriteKeywords() {
        let connId = connectionId
        Task { @MainActor in
            let keywords = await SQLFavoriteManager.shared.fetchKeywordMap(connectionId: connId)
            completionAdapter?.updateFavoriteKeywords(keywords)
        }
    }

    private func teardownFavoritesObserver() {
        if let observer = favoritesObserver {
            NotificationCenter.default.removeObserver(observer)
            favoritesObserver = nil
        }
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
            peripherals: .init(
                showGutter: ThemeEngine.shared.showLineNumbers,
                showMinimap: false,
                showFoldingRibbon: false
            )
        )
    }
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
