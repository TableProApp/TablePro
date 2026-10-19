//
//  SQLStatementPreview.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProEditorKit
import TableProGrammars
import TableProPluginKit

/// One owner for the choice between the editor and the plain text view, so two surfaces never show the
/// same statement two ways.
struct SQLStatementPreview: View {
    @ObservedObject private var settingsManager = AppSettingsManager.shared
    let prepared: SQLReviewSheet.Prepared
    let databaseType: DatabaseType

    @State private var editorState: SourceEditorState?
    @State private var editorConfiguration = makeConfiguration()

    var body: some View {
        switch prepared.mode {
        case .rich:
            richEditor(prepared.display)
        case .plain, .truncated:
            plainTextEditor(prepared.display)
        }
    }

    private func richEditor(_ text: String) -> some View {
        let stateBinding = Binding<SourceEditorState>(
            get: { editorState ?? SourceEditorState() },
            set: { editorState = $0 }
        )
        return SourceEditor(
            .constant(text),
            language: PluginManager.shared.editorLanguage(for: databaseType).treeSitterLanguage,
            configuration: editorConfiguration,
            state: stateBinding,
            foldProvider: FoldProviderResolver.provider(for: databaseType)
        )
        .onReceive(AppEvents.shared.themeChanged) { _ in
            editorConfiguration = Self.makeConfiguration()
        }
        .onChange(of: settingsManager.editor) { _ in
            editorConfiguration = Self.makeConfiguration()
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    /// A text view, since this path carries a statement of any length and a `Text` that size lays out for seconds.
    private func plainTextEditor(_ text: String) -> some View {
        HighlightedSQLTextView(sql: text, databaseType: databaseType)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
    }

    static func makeConfiguration() -> SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: ThemeEngine.shared.makeEditorTheme(),
                font: ThemeEngine.shared.editorFonts.font,
                wrapLines: true
            ),
            behavior: .init(isEditable: false),
            layout: .init(
                contentInsets: NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            ),
            peripherals: EditorPeripherals.preview(
                folding: AppSettingsManager.shared.editor.codeFoldingEnabled
            )
        )
    }
}
