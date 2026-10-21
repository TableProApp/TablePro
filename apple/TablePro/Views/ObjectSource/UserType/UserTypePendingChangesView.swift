//
//  UserTypePendingChangesView.swift
//  TablePro
//

import SwiftUI

/// The queue, in the order it runs, with the server's answer on the change it refused.
struct UserTypePendingChangesView: View {
    @ObservedObject var model: UserTypeEditorModel
    let canSave: Bool
    let onPreviewSQL: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !model.changes.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.changes) { change in
                            row(change)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                Divider()
            }
            bar
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("user-type-pending-changes")
    }

    private func row(_ change: StagedTypeChange) -> some View {
        let message = model.message(for: change)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: message == nil ? "circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(message == nil ? Color.secondary : Color.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.summary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Button {
                model.remove(change.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(model.isSaving)
            .help(String(localized: "Remove this change from the queue"))
            .accessibilityLabel(String(format: String(localized: "Remove “%@”"), change.summary))
        }
        .font(.subheadline)
    }

    private var bar: some View {
        HStack(spacing: 12) {
            if let summary = model.saveSummary {
                Label(summary, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Label {
                    Text("^[\(model.changes.count) change](inflect: true)")
                } icon: {
                    Image(systemName: "square.and.pencil")
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "Discard")) { model.discardChanges() }
                .disabled(!model.hasChanges || model.isSaving)
                .accessibilityIdentifier("user-type-discard")
            Button(String(localized: "Preview SQL"), action: onPreviewSQL)
                .disabled(!model.hasChanges || model.isSaving)
                .accessibilityIdentifier("user-type-preview-sql")
            Button(String(localized: "Save Changes"), action: onSave)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || !model.hasChanges || model.isSaving)
                .accessibilityIdentifier("user-type-save")
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .paneBarBackground(Color(nsColor: .controlBackgroundColor))
    }
}
