//
//  SQLCodePreview.swift
//  TablePro
//
//  Read-only SQL code preview with tree-sitter syntax highlighting
//

import SwiftUI
import TableProEditorKit
import TableProGrammars

/// Read-only SQL code preview with syntax highlighting powered by TableProEditorKit
struct SQLCodePreview: View {
    @ObservedObject private var settingsManager = AppSettingsManager.shared
    @Binding var text: String

    @State private var editorState = SourceEditorState()
    @State private var editorConfiguration = makeConfiguration()

    var body: some View {
        SourceEditor(
            $text,
            language: .sql,
            configuration: editorConfiguration,
            state: $editorState,
            foldProvider: FoldProviderResolver.provider(for: CodeLanguage.sql)
        )
        .onReceive(AppEvents.shared.themeChanged) { _ in
            editorConfiguration = Self.makeConfiguration()
        }
    }

    // MARK: - Configuration

    private static func makeConfiguration() -> SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: TableProEditorTheme.make(),
                font: ThemeEngine.shared.editorFonts.font,
                wrapLines: false
            ),
            behavior: .init(
                isEditable: false
            ),
            layout: .init(
                contentInsets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
            ),
            peripherals: EditorPeripherals.inline(
                lineNumbers: true,
                folding: AppSettingsManager.shared.editor.codeFoldingEnabled
            )
        )
    }
}
