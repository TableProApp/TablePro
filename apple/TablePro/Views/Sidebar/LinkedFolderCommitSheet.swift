//
//  LinkedFolderCommitSheet.swift
//  TablePro
//

import SwiftUI

internal struct LinkedFolderCommitTarget: Identifiable {
    let folder: LinkedSQLFolder
    var preselectedPath: String?

    var id: String { folder.id.uuidString + "/" + (preselectedPath ?? "") }
}

internal struct LinkedFolderCommitSheet: View {
    @StateObject private var model: LinkedFolderCommitModel
    @ObservedObject private var gitActions = LinkedFolderGitActions.shared
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isMessageFocused: Bool

    init(target: LinkedFolderCommitTarget) {
        _model = StateObject(wrappedValue: LinkedFolderCommitModel(
            folder: target.folder,
            preselectedPath: target.preselectedPath
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: 780, minHeight: 460, idealHeight: 580)
        .task {
            await model.load()
            if model.phase == .ready, !model.draft.entries.isEmpty {
                isMessageFocused = true
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Commit Changes")
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        guard let branch = model.branch else { return model.folder.name }
        return String(format: String(localized: "%@ on branch %@"), model.folder.name, branch)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .loadFailed(let message):
            UnavailableStateView {
                Label(String(localized: "Changes Unavailable"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(String(localized: "Try Again")) {
                    Task { await model.load() }
                }
            }
        case .ready, .committing:
            if model.draft.entries.isEmpty {
                UnavailableStateView(
                    String(localized: "No Changes"),
                    systemImage: "checkmark.circle",
                    description: Text("Every file in this folder matches the last commit.")
                )
            } else {
                VStack(spacing: 0) {
                    HSplitView {
                        fileList
                            .frame(minWidth: 200, idealWidth: 250, maxWidth: 360)
                        diffPane
                            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Divider()
                    messageEditor
                }
            }
        }
    }

    private var fileList: some View {
        List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
            ForEach(model.draft.entries) { entry in
                fileRow(entry)
                    .tag(entry.id)
            }
        }
        .listStyle(.inset)
        .disabled(model.phase == .committing)
        .accessibilityLabel(String(localized: "Changed Files"))
    }

    private func fileRow(_ entry: LinkedFolderCommitEntry) -> some View {
        HStack(spacing: 6) {
            Toggle(entry.folderRelativePath, isOn: Binding(
                get: { model.draft.isChecked(entry) },
                set: { model.setChecked(entry, $0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!entry.canCommit)
            .help(entry.canCommit ? "" : String(localized: "Resolve the conflict in a Git client before committing this file."))
            Text(entry.folderRelativePath)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(entry.folderRelativePath)
            Spacer(minLength: 4)
            Text(verbatim: entry.status.badge.letter)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
                .help(entry.status.accessibilityDescription)
                .accessibilityLabel(entry.status.accessibilityDescription)
        }
    }

    @ViewBuilder
    private var diffPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let entry = model.selectedEntry, model.unsavedPaths.contains(entry.id) {
                Label(
                    String(localized: "This file has unsaved changes in an editor tab. The commit takes the saved file."),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
            }
            diffBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var diffBody: some View {
        switch model.diff {
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .comparison(.identical):
            UnavailableStateView(
                String(localized: "No Text Changes"),
                systemImage: "equal.circle",
                description: Text("The text matches the last commit.")
            )
        case .comparison(.tooLarge):
            UnavailableStateView(
                String(localized: "Too Large to Compare"),
                systemImage: "doc.text.magnifyingglass",
                description: Text("This file is too large to compare line by line.")
            )
        case .comparison(.differs(let pairs)):
            ScrollView {
                TextDiffView(
                    pairs: pairs,
                    beforeLabel: String(localized: "Last Commit"),
                    afterLabel: String(localized: "Working Copy"),
                    layout: .unified,
                    textFont: .system(.body, design: .monospaced)
                )
                .padding(12)
            }
        case .binary:
            UnavailableStateView(
                String(localized: "Binary File"),
                systemImage: "doc",
                description: Text("This file can't be shown as text.")
            )
        case .unavailable(let message):
            UnavailableStateView(
                String(localized: "Diff Unavailable"),
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        }
    }

    private var messageEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Message")
                .font(.subheadline.weight(.semibold))
            TextEditor(text: $model.draft.message)
                .font(.body)
                .frame(height: 72)
                .focused($isMessageFocused)
                .disabled(model.phase == .committing)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor))
                )
                .accessibilityLabel(String(localized: "Commit Message"))
            if let error = model.commitError {
                commitErrorView(error)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func commitErrorView(_ error: LinkedFolderGitError) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(error.errorDescription ?? "")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            if let output = error.output {
                ScrollView {
                    Text(verbatim: output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 90)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.phase == .committing {
                ProgressView()
                    .controlSize(.small)
                Text(LinkedFolderGitOperation.commit.progressLabel)
                    .foregroundStyle(.secondary)
            } else if model.isBusy {
                Text("Another Git command is still running in this repository.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "Cancel")) {
                model.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(String(localized: "Commit")) {
                Task {
                    if await model.commit() {
                        dismiss()
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canCommit)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
