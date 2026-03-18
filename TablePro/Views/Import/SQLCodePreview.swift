//
//  SQLCodePreview.swift
//  TablePro
//
//  Read-only SQL code preview with tree-sitter syntax highlighting
//

import CodeEditLanguages
import CodeEditSourceEditor
import SwiftUI

/// Read-only SQL code preview with syntax highlighting powered by CodeEditSourceEditor
struct SQLCodePreview: View {
    @Binding var text: String

    @State private var editorState = SourceEditorState()
    @State private var editorConfiguration = makeConfiguration()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if text.isEmpty {
            Color(nsColor: .textBackgroundColor)
        } else {
            SourceEditor(
                $text,
                language: .sql,
                configuration: editorConfiguration,
                state: $editorState
            )
            .onChange(of: colorScheme) {
                editorConfiguration = Self.makeConfiguration()
            }
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
            peripherals: .init(
                showGutter: true,
                showMinimap: false,
                showFoldingRibbon: false
            )
        )
    }
}
