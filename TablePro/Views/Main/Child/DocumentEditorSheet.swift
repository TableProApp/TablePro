//
//  DocumentEditorSheet.swift
//  TablePro
//

import SwiftUI

/// Inserts a document written as Extended JSON.
///
/// A grid can only write into the fields its sampled documents already have, so a collection with
/// no documents has nowhere to type the first field. The whole document is the unit a document
/// store writes, so a new document's fields are typed into the document itself.
struct DocumentEditorSheet: View {
    private enum Phase: Equatable {
        case editing
        case saving
    }

    @Environment(\.dismiss) private var dismiss

    let request: DocumentEditorRequest
    let databaseType: DatabaseType

    @State private var text = "{\n  \n}"
    @State private var phase = Phase.editing
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            buttonBar
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Insert Document")
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

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            JSONCodeEditor(text: $text, isEditable: phase == .editing, accessibilityIdentifier: "document-editor")
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
                Text("Quote every field name. An ObjectId is {\"$oid\": \"…\"} and a date is {\"$date\": \"…\"}.")
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
            Button(String(localized: "Cancel")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(String(localized: "Insert")) {
                Task { await save() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(phase != .editing)
            .accessibilityIdentifier("document-editor-submit")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func save() async {
        phase = .saving
        saveError = nil
        do {
            try await DocumentEditing.insert(text, for: request, databaseType: databaseType)
            dismiss()
        } catch {
            saveError = error.localizedDescription
            phase = .editing
        }
    }
}
