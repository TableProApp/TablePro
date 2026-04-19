//
//  DDLTextView.swift
//  TablePro
//
//  Read-only DDL view with tree-sitter syntax highlighting via CodeEditSourceEditor
//

import CodeEditLanguages
import CodeEditSourceEditor
import SwiftUI
import TableProPluginKit

/// Read-only DDL display with syntax highlighting powered by CodeEditSourceEditor
struct DDLTextView: View {
    @Binding var ddl: String
    @Binding var fontSize: CGFloat
    var databaseType: DatabaseType?

    @State private var editorState = SourceEditorState()
    @State private var editorConfiguration: SourceEditorConfiguration
    @Environment(\.colorScheme) private var colorScheme

    /// Primary initializer with bindings
    init(ddl: Binding<String>, fontSize: Binding<CGFloat>, databaseType: DatabaseType? = nil) {
        self._ddl = ddl
        self._fontSize = fontSize
        self.databaseType = databaseType
        self._editorConfiguration = State(wrappedValue: Self.makeConfiguration(fontSize: fontSize.wrappedValue))
    }

    /// Convenience initializer for non-binding DDL text (read-only display)
    init(ddl: String, fontSize: Binding<CGFloat>, databaseType: DatabaseType? = nil) {
        self._ddl = .constant(ddl)
        self._fontSize = fontSize
        self.databaseType = databaseType
        self._editorConfiguration = State(wrappedValue: Self.makeConfiguration(fontSize: fontSize.wrappedValue))
    }

    var body: some View {
        if ddl.isEmpty {
            Color(nsColor: .textBackgroundColor)
        } else {
            SourceEditor(
                $ddl,
                language: resolvedLanguage,
                configuration: editorConfiguration,
                state: $editorState
            )
            .onChange(of: colorScheme) {
                editorConfiguration = Self.makeConfiguration(fontSize: fontSize)
            }
            .onChange(of: fontSize) { _, newSize in
                editorConfiguration = Self.makeConfiguration(fontSize: newSize)
            }
        }
    }

    private var resolvedLanguage: CodeLanguage {
        if let databaseType {
            return PluginManager.shared.editorLanguage(for: databaseType).treeSitterLanguage
        }
        return .sql
    }

    private static func makeConfiguration(fontSize: CGFloat) -> SourceEditorConfiguration {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return SourceEditorConfiguration(
            appearance: .init(
                theme: TableProEditorTheme.make(),
                font: font,
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
