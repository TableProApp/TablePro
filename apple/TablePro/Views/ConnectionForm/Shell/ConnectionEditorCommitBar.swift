//
//  ConnectionEditorCommitBar.swift
//  TablePro
//

import SwiftUI

// What the bar's buttons ask the window for: each ends editing first, so a half-typed value counts.
struct ConnectionEditorCommitActions {
    var test: () -> Void
    var save: () -> Void
    var commit: () -> Void
    var cancel: () -> Void
    var copyURL: () -> Void
    var delete: () -> Void
}

// Full width under the sidebar and the detail, as a sidebar editor with several bottom controls has it.
struct ConnectionEditorCommitBar: View {
    @ObservedObject var store: ConnectionEditorStore
    let actions: ConnectionEditorCommitActions

    // One stable container carries the presentations, so a sheet stays up if the record goes missing under it.
    var body: some View {
        VStack(spacing: 0) {
            if store.isRecordMissing {
                Color.clear.frame(height: 0)
            } else {
                Divider()
                bar
            }
        }
        .modifier(ConnectionEditorPresentations(store: store))
    }

    private var bar: some View {
        HStack(spacing: 12) {
            moreMenu
            testButton
            ConnectionEditorCommitStatus(store: store)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(String(localized: "Cancel"), action: actions.cancel)
                .keyboardShortcut(.cancelAction)
                .fixedSize()
                .accessibilityIdentifier("connection-form-cancel")
            if store.isNew {
                Button(String(localized: "Save"), action: actions.save)
                    .disabled(!store.canSave)
                    .fixedSize()
                    .accessibilityIdentifier("connection-form-save")
            }
            Button(store.isNew ? String(localized: "Save & Connect") : String(localized: "Save"), action: actions.commit)
                .keyboardShortcut(.defaultAction)
                .disabled(!store.canSave)
                .fixedSize()
                .accessibilityIdentifier(store.isNew ? "connection-form-save-connect" : "connection-form-save")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var moreMenu: some View {
        Menu {
            Button(String(localized: "Copy as URL"), action: actions.copyURL)
            if store.canDelete {
                Divider()
                Button(String(localized: "Delete…"), role: .destructive, action: actions.delete)
            }
        } label: {
            Label(String(localized: "More"), systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "More"))
        .accessibilityLabel(String(localized: "More"))
        .accessibilityIdentifier("connection-form-more")
    }

    private var testButton: some View {
        Button(store.isTesting ? String(localized: "Cancel Test") : String(localized: "Test Connection"), action: actions.test)
            .disabled(!store.isTesting && !store.canTest)
            .fixedSize()
            .accessibilityIdentifier("connection-form-test")
    }
}

// One line, truncating, the whole text in the tooltip.
struct ConnectionEditorCommitStatus: View {
    @ObservedObject var store: ConnectionEditorStore

    var body: some View {
        if store.isLibraryUnreadable {
            let message = ConnectionEditorSaveError.libraryUnreadable.errorDescription ?? ""
            NoticeLabel(message, severity: .error)
                .lineLimit(1)
                .help(message)
        } else if store.testState != .idle {
            // A test result outranks a blocking issue: Test needs no name, and its result would never show otherwise.
            testStatus
        } else if let issue = store.firstBlockingIssue {
            Button {
                store.focus(on: issue)
            } label: {
                NoticeLabel(issue.message, severity: .error)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(issue.message)
            .accessibilityHint(String(localized: "Shows the setting to fix"))
            .accessibilityIdentifier("connection-form-validation")
        }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch store.testState {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "Testing…"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("connection-form-test-status")
        case .succeeded(let success):
            HStack(spacing: 6) {
                NoticeLabel(success.summary, severity: success.warning == nil ? .success : .warning)
                    .lineLimit(1)
                    .help([success.summary, success.warning].compactMap { $0 }.joined(separator: "\n"))
                    .accessibilityIdentifier("connection-form-test-status")
                if let warning = success.warning {
                    ConnectionTestDetailsButton {
                        ConnectionTestDetails(title: success.summary, message: warning)
                    }
                    .accessibilityIdentifier("connection-form-test-warning")
                }
            }
        case .failed(let failure):
            HStack(spacing: 6) {
                NoticeLabel(failure.summary, severity: .error)
                    .lineLimit(1)
                    .help([failure.summary, failure.message].joined(separator: "\n"))
                    .accessibilityIdentifier("connection-form-test-status")
                ConnectionTestDetailsButton {
                    ConnectionTestDetails(
                        title: failure.step.title,
                        message: failure.message,
                        recoverySuggestion: failure.recoverySuggestion,
                        recoveryTitle: failure.recoveryAction?.title,
                        recover: { store.performTestRecovery() }
                    )
                }
            }
        }
    }
}

private struct ConnectionTestDetailsButton<Details: View>: View {
    @ViewBuilder let details: () -> Details
    @State private var isShowingDetails = false

    var body: some View {
        Button {
            isShowingDetails = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .help(String(localized: "Details"))
        .accessibilityLabel(String(localized: "Details"))
        .popover(isPresented: $isShowingDetails, arrowEdge: .top) {
            details()
        }
    }
}

// Read only: what failed, the server's own words, and the one fix TablePro can start.
private struct ConnectionTestDetails: View {
    let title: String
    let message: String
    var recoverySuggestion: String?
    var recoveryTitle: String?
    var recover: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let recoverySuggestion, !recoverySuggestion.isEmpty {
                Text(recoverySuggestion)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let recoveryTitle {
                Button(recoveryTitle) {
                    dismiss()
                    recover()
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}
