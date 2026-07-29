//
//  TriggerEditorView.swift
//  TablePro
//
//  DDL-first editor sheet for creating and editing triggers.
//

import CodeEditLanguages
import CodeEditSourceEditor
import SwiftUI
import TableProPluginKit

struct TriggerEditorView: View {
    enum Mode {
        case create
        case edit(originalName: String, originalDefinition: String)
    }

    let connection: DatabaseConnection
    let tableName: String
    let mode: Mode
    let onClose: () -> Void

    @State private var sql: String
    @State private var editorState = SourceEditorState()
    @State private var editorConfiguration: SourceEditorConfiguration
    @State private var isApplying = false
    @State private var errorMessage: String?
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("structureCodeFontSize") private var fontSize: Double = 13

    init(connection: DatabaseConnection, tableName: String, mode: Mode, initialSQL: String, onClose: @escaping () -> Void) {
        self.connection = connection
        self.tableName = tableName
        self.mode = mode
        self.onClose = onClose
        self._sql = State(wrappedValue: initialSQL)
        self._editorConfiguration = State(wrappedValue: Self.makeConfiguration(fontSize: 13))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            SourceEditor(
                $sql,
                language: PluginManager.shared.editorLanguage(for: connection.type).treeSitterLanguage,
                configuration: editorConfiguration,
                state: $editorState
            )
            if let errorMessage {
                Divider()
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 360, idealHeight: 460)
        .onChange(of: colorScheme) {
            editorConfiguration = Self.makeConfiguration(fontSize: fontSize)
        }
        .onChange(of: fontSize) { _, newSize in
            editorConfiguration = Self.makeConfiguration(fontSize: newSize)
        }
    }

    private var header: some View {
        HStack {
            Text(isEdit ? "Edit Trigger" : "New Trigger")
                .font(.headline)
            Spacer()
            Button("Cancel", role: .cancel) { onClose() }
                .keyboardShortcut(.cancelAction)
            Button(isEdit ? "Save" : "Create") { apply() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isApplying)
        }
        .padding()
    }

    private var isEdit: Bool {
        if case .edit = mode { return true }
        return false
    }

    private func apply() {
        isApplying = true
        errorMessage = nil
        let originalName: String?
        let originalDefinition: String?
        switch mode {
        case .create:
            originalName = nil
            originalDefinition = nil
        case let .edit(name, definition):
            originalName = name
            originalDefinition = definition
        }
        Task {
            defer { isApplying = false }
            do {
                try await TriggerEditing.apply(
                    connection: connection,
                    tableName: tableName,
                    sql: sql,
                    isEdit: isEdit,
                    originalName: originalName,
                    originalDefinition: originalDefinition
                )
                onClose()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func makeConfiguration(fontSize: Double) -> SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: TableProEditorTheme.make(),
                font: NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular),
                wrapLines: false
            ),
            behavior: .init(isEditable: true),
            layout: .init(contentInsets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)),
            peripherals: .init(showGutter: true, showMinimap: false, showFoldingRibbon: false)
        )
    }
}
