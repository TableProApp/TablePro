//
//  SQLCodePreview.swift
//  TablePro
//
//  Read-only SQL code preview with syntax highlighting
//

import SwiftUI

/// Read-only SQL code preview with syntax highlighting powered by TPEditorView
struct SQLCodePreview: View {
    @Binding var text: String

    @State private var cursorRange = NSRange(location: 0, length: 0)
    @State private var editorConfiguration = makeConfiguration()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if text.isEmpty {
            Color(nsColor: .textBackgroundColor)
        } else {
            TPEditorView(
                text: $text,
                cursorRange: $cursorRange,
                configuration: editorConfiguration
            )
            .onChange(of: colorScheme) {
                editorConfiguration = Self.makeConfiguration()
            }
        }
    }

    // MARK: - Configuration

    private static func makeConfiguration() -> TPEditorConfiguration {
        let theme = ThemeEngine.shared
        return TPEditorConfiguration(
            font: theme.editorFonts.font,
            theme: theme.makeTPEditorTheme(),
            wrapLines: false,
            showLineNumbers: true,
            showCurrentLineHighlight: false,
            tabWidth: 4,
            autoIndent: false,
            isEditable: false,
            contentInsets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        )
    }
}
