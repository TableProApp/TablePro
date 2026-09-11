//
//  ObjectCommentSheet.swift
//  TablePro
//

import os
import SwiftUI

/// Edits the comment on one table, view, materialized view or foreign table.
///
/// A sheet with an explicit Save rather than a field that commits on its own: the write is a
/// statement against the server, and a popover or an inspector field that saves when it loses
/// focus would run it on a stray click.
struct ObjectCommentSheet: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ObjectCommentSheet")

    private enum Phase: Equatable {
        case loading
        case editing
        case saving
        case loadFailed(String)
    }

    @Environment(\.dismiss) private var dismiss

    let target: DatabaseObjectTarget
    let connection: DatabaseConnection

    @State private var draft = ObjectCommentDraft(original: nil)
    @State private var phase: Phase = .loading
    @State private var saveError: String?
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            buttonBar
        }
        .frame(width: 480, height: 320)
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Edit Comment")
                .font(.headline)
            Text(target.qualifiedName)
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
        switch phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loadFailed(let message):
            ContentUnavailableView {
                Label("Comment Unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    Task { await load() }
                }
            }
        case .editing, .saving:
            editor
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $draft.text)
                .font(ThemeEngine.shared.valueFontSwiftUI)
                .focused($isEditorFocused)
                .disabled(phase == .saving)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor))
                )
                .accessibilityLabel(String(localized: "Comment"))
                .accessibilityIdentifier("object-comment-editor")
            if let saveError {
                Text(saveError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text("Leave the comment empty to remove it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
            Button(draft.removesComment ? String(localized: "Remove Comment") : String(localized: "Save")) {
                Task { await save() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(phase != .editing || !draft.hasChanges)
            .accessibilityIdentifier("object-comment-save")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func load() async {
        phase = .loading
        do {
            let comment = try await ObjectCommentEditing.currentComment(of: target)
            draft = ObjectCommentDraft(original: comment)
            phase = .editing
            isEditorFocused = true
        } catch {
            Self.logger.error("Failed to read comment: \(error.localizedDescription, privacy: .public)")
            phase = .loadFailed(error.localizedDescription)
        }
    }

    private func save() async {
        phase = .saving
        saveError = nil
        do {
            try await ObjectCommentEditing.setComment(draft.commentToSave, on: target, connection: connection)
            dismiss()
        } catch {
            saveError = error.localizedDescription
            phase = .editing
        }
    }
}
