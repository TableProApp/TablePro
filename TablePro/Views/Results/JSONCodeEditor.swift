//
//  JSONCodeEditor.swift
//  TablePro
//
//  JSON text view backed by CodeEditSourceEditor (tree-sitter), sharing the
//  app's editor theme and font with the SQL editor.
//

import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import SwiftUI

internal struct JSONCodeEditor: View {
    @Binding var text: String
    let isEditable: Bool

    @State private var editorState = SourceEditorState()
    @State private var configuration: SourceEditorConfiguration
    @Environment(\.colorScheme) private var colorScheme

    init(text: Binding<String>, isEditable: Bool) {
        self._text = text
        self.isEditable = isEditable
        self._configuration = State(wrappedValue: Self.makeConfiguration(isEditable: isEditable))
    }

    var body: some View {
        SourceEditor(
            $text,
            language: .json,
            configuration: configuration,
            state: $editorState
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: colorScheme) {
            configuration = Self.makeConfiguration(isEditable: isEditable)
        }
    }

    private static func makeConfiguration(isEditable: Bool) -> SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: TableProEditorTheme.make(),
                font: ThemeEngine.shared.editorFonts.font,
                wrapLines: true
            ),
            behavior: .init(
                isEditable: isEditable
            ),
            layout: .init(
                contentInsets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
            ),
            peripherals: .init(
                showGutter: false,
                showMinimap: false,
                showFoldingRibbon: false
            )
        )
    }
}
