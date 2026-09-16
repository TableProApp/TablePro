//
//  SQLStatementPreview.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProEditorKit
import TableProGrammars
import TableProPluginKit

/// Read-only statement text, rendered the one way the app renders statement text.
///
/// Extracted from `SQLReviewSheet` rather than copied, because the choice between the tree-sitter
/// editor and the plain highlighted text view is a policy about statement length and language, not
/// a detail of the review sheet: a second surface that picked differently would show the same
/// `CREATE SCHEMA` two ways.
struct SQLStatementPreview: View {
    let prepared: SQLReviewSheet.Prepared
    let databaseType: DatabaseType

    @State private var editorState: SourceEditorState?

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
            configuration: SQLStatementPreview.makeConfiguration(),
            state: stateBinding,
            foldProvider: FoldProviderResolver.provider(for: databaseType)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    /// A text view rather than a `Text` in a `ScrollView`: this path carries everything past the
    /// tree-sitter cutoff, which for a confirmation is the whole statement however long it is, and
    /// a single `Text` that size lays out for seconds. It wears the editor's own background, text
    /// colour and syntax palette, which is what a hand-themed `Text` here was reaching for.
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
                theme: TableProEditorTheme.make(),
                font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
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
