//
//  JSONCodeEditor.swift
//  TablePro
//
//  JSON text view backed by TableProEditorKit (tree-sitter), sharing the
//  app's editor theme and font with the SQL editor.
//

import AppKit
import SwiftUI
import TableProEditorKit
import TableProGrammars

internal struct JSONCodeEditor: View {
    @ObservedObject private var settingsManager = AppSettingsManager.shared
    @ObservedObject private var themeEngine = ThemeEngine.shared
    @Binding var text: String
    let isEditable: Bool

    @State private var editorState = SourceEditorState()
    @State private var configuration: SourceEditorConfiguration
    /// Held in `@State` so the editor is handed the same coordinator on every update. It names the
    /// text view itself, which is where an accessibility identifier has to land: the SwiftUI
    /// modifier names the representable and never reaches it.
    @State private var coordinators: [any TextViewCoordinator]
    @Environment(\.colorScheme) private var colorScheme

    init(text: Binding<String>, isEditable: Bool, accessibilityIdentifier: String? = nil) {
        self._text = text
        self.isEditable = isEditable
        self._configuration = State(wrappedValue: Self.makeConfiguration(isEditable: isEditable))
        self._coordinators = State(
            wrappedValue: accessibilityIdentifier.map { [EditorAccessibilityIdentifier($0)] } ?? []
        )
    }

    var body: some View {
        SourceEditor(
            $text,
            language: .json,
            configuration: configuration,
            state: $editorState,
            coordinators: coordinators
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: colorScheme) { _ in
            rebuildConfiguration()
        }
        .onChange(of: isEditable) { _ in
            rebuildConfiguration()
        }
        .onChange(of: settingsManager.editor) { _ in
            rebuildConfiguration()
        }
        .onReceive(AppEvents.shared.accessibilityTextSizeChanged) { _ in
            rebuildConfiguration()
        }
        .onReceive(AppEvents.shared.themeChanged) { _ in
            rebuildConfiguration()
        }
    }

    private func rebuildConfiguration() {
        configuration = Self.makeConfiguration(isEditable: isEditable)
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
            peripherals: EditorPeripherals.preview(
                folding: AppSettingsManager.shared.editor.codeFoldingEnabled,
                invisibleCharacters: !isEditable || AppSettingsManager.shared.editor.showInvisibleCharacters
            )
        )
    }
}
