//
//  SQLEditorView.swift
//  TablePro
//
//  SwiftUI wrapper for the NSTextView-based SQL editor.
//  Bridges between the new TPEditorView and the existing coordinator/completion systems.
//

import AppKit
import SwiftUI

// MARK: - SQLEditorView

struct SQLEditorView: View {
    @Binding var text: String
    @Binding var cursorPositions: [NSRange]
    var schemaProvider: SQLSchemaProvider?
    var databaseType: DatabaseType?
    var connectionId: UUID?
    @Binding var vimMode: VimMode
    var onCloseTab: (() -> Void)?
    var onExecuteQuery: (() -> Void)?
    var onAIExplain: ((String) -> Void)?
    var onAIOptimize: ((String) -> Void)?
    var onSaveAsFavorite: ((String) -> Void)?

    @State private var coordinator = SQLEditorCoordinator()
    @State private var cursorRange = NSRange(location: 0, length: 0)
    @State private var editorConfiguration = makeConfiguration()
    @State private var favoritesObserver: NSObjectProtocol?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TPEditorView(
            text: $text,
            cursorRange: $cursorRange,
            configuration: editorConfiguration,
            editorDelegate: coordinator,
            onTextViewCreated: { textView in
                coordinator.install(on: textView)
            }
        )
        .onChange(of: cursorRange) { _, newRange in
            cursorPositions = [newRange]
        }
        .onChange(of: connectionId) { _, _ in
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
        .onChange(of: coordinator.vimMode) { _, newMode in
            vimMode = newMode
        }
        .onAppear {
            coordinator.schemaProvider = schemaProvider
            coordinator.onCloseTab = onCloseTab
            coordinator.onExecuteQuery = onExecuteQuery
            coordinator.onAIExplain = onAIExplain
            coordinator.onAIOptimize = onAIOptimize
            coordinator.onSaveAsFavorite = onSaveAsFavorite
            setupFavoritesObserver()
        }
        .onDisappear {
            coordinator.destroy()
            teardownFavoritesObserver()
        }
    }

    // MARK: - Favorites

    private func setupFavoritesObserver() {
        teardownFavoritesObserver()
        let connId = connectionId
        favoritesObserver = NotificationCenter.default.addObserver(
            forName: .sqlFavoritesDidUpdate,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                _ = await SQLFavoriteManager.shared.fetchKeywordMap(connectionId: connId)
            }
        }
    }

    private func teardownFavoritesObserver() {
        if let observer = favoritesObserver {
            NotificationCenter.default.removeObserver(observer)
            favoritesObserver = nil
        }
    }

    // MARK: - Configuration

    private static func makeConfiguration() -> TPEditorConfiguration {
        let theme = ThemeEngine.shared
        return TPEditorConfiguration(
            font: theme.editorFonts.font,
            theme: theme.makeTPEditorTheme(),
            wrapLines: theme.wordWrap,
            showLineNumbers: theme.showLineNumbers,
            showCurrentLineHighlight: theme.highlightCurrentLine,
            tabWidth: theme.tabWidth,
            autoIndent: theme.autoIndent,
            isEditable: true,
            contentInsets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
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
