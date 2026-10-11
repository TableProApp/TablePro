//
//  DocumentEditorSheet.swift
//  TablePro
//

import SwiftUI

/// Inserts a document written as Extended JSON, or edits a stored one as that text.
///
/// A grid can only write into the fields its sampled documents already have, so a collection with
/// no documents has nowhere to type the first field, and a field cannot be added, renamed or removed
/// from a cell. The whole document is the unit a document store writes, so it is edited whole.
struct DocumentEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let request: DocumentEditorRequest
    let databaseType: DatabaseType

    @State private var text: String
    @State private var original: String?
    @State private var phase: DocumentEditorPresentation.Phase
    @State private var saveError: String?

    init(request: DocumentEditorRequest, databaseType: DatabaseType) {
        self.request = request
        self.databaseType = databaseType
        _text = State(initialValue: request.kind == .insert ? "{\n  \n}" : "")
        _phase = State(initialValue: DocumentEditorPresentation.initialPhase(for: request.kind))
    }

    private var presentation: DocumentEditorPresentation {
        DocumentEditorPresentation(kind: request.kind, phase: phase)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            buttonBar
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 560)
        .interactiveDismissDisabled(presentation.dismissDisabled)
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(presentation.title)
                .font(.headline)
            Text(request.table)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if presentation.showsEditor {
            editor
        } else if let message = presentation.message {
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(20)
                .accessibilityIdentifier("document-editor-message")
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("document-editor-loading")
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            JSONCodeEditor(text: $text, isEditable: presentation.isEditable, accessibilityIdentifier: "document-editor")
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor))
                )
            if let saveError {
                Text(saveError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("document-editor-error")
            } else {
                Text(presentation.hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
    }

    private var buttonBar: some View {
        HStack {
            if phase == .saving {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button(presentation.cancelTitle) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(!presentation.canCancel)
            if presentation.showsSave {
                Button(presentation.saveTitle) {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!presentation.canSave)
                .accessibilityIdentifier("document-editor-submit")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func load() async {
        guard phase == .loading else { return }
        do {
            guard let stored = try await DocumentEditing.load(request) else {
                phase = .missing
                return
            }
            original = stored
            text = stored
            phase = .editing
        } catch {
            guard !Task.isCancelled else { return }
            phase = .loadFailed(error.localizedDescription)
        }
    }

    private func save() async {
        phase = .saving
        saveError = nil
        do {
            try await DocumentEditing.save(text, original: original, for: request, databaseType: databaseType)
            dismiss()
        } catch {
            saveError = error.localizedDescription
            phase = .editing
        }
    }
}
