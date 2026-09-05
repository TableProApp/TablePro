//
//  ConnectionFormActionBar.swift
//  TablePro
//

import AppKit
import SwiftUI

/// The window's commit actions, and the reason they are unavailable.
///
/// macOS puts the buttons that commit an editor window at the bottom trailing edge rather than in
/// the titlebar, and it leaves the leading edge for the status the buttons depend on. That pairing
/// is the point here: a disabled Save is only actionable next to the field it is waiting for.
struct ConnectionFormActionBar: View {
    @Bindable var coordinator: ConnectionFormCoordinator

    /// Walked once per body evaluation and read four times from it.
    ///
    /// Every read costs three `PluginManager.additionalConnectionFields` calls, several locked
    /// `PluginMetadataRegistry` lookups and an `SSHConfiguration` allocation, and this view observes
    /// the connection name, so it re-evaluates on every keystroke in the Name field.
    var body: some View {
        let issues = coordinator.validationIssues
        let canCommit = issues.isEmpty && !coordinator.isInstallingPlugin

        return HStack(spacing: 12) {
            deleteButton
            validationMessage(issues)
            Spacer(minLength: 12)
            TestConnectionStatusButton(coordinator: coordinator)
            Button(String(localized: "Cancel")) {
                coordinator.cancel()
            }
            .keyboardShortcut(.cancelAction)
            if coordinator.isNew {
                Button(String(localized: "Save")) {
                    coordinator.save()
                }
                .disabled(!canCommit)
            }
            Button(defaultActionTitle) {
                coordinator.commit()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canCommit)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Restores the Delete the editor shipped through 0.38.0.
    ///
    /// It sat at `ToolbarItemPlacement.destructiveAction` until #995 rebuilt the form and dropped
    /// the button while porting its body into `ConnectionFormCoordinator.deleteCurrent()`, which
    /// has had no caller since. The window has no toolbar now, so it takes the bottom bar's leading
    /// edge, which is where `SSHProfileEditorView` already puts the same action.
    @ViewBuilder
    private var deleteButton: some View {
        if !coordinator.isNew {
            Button(String(localized: "Delete"), role: .destructive) {
                confirmDelete()
            }
            .accessibilityIdentifier("connection-form-delete")
        }
    }

    private func confirmDelete() {
        Task {
            let confirmed = await AlertHelper.confirmDestructive(
                title: String(localized: "Delete Connection"),
                message: String(localized: "Are you sure you want to delete this connection? This cannot be undone."),
                confirmButton: String(localized: "Delete"),
                window: NSApp.keyWindow
            )
            if confirmed {
                coordinator.deleteCurrent()
            }
        }
    }

    private var defaultActionTitle: String {
        coordinator.isNew
            ? String(localized: "Save & Connect")
            : String(localized: "Save")
    }

    /// Names the tab as well as the issue whenever the issue is on a tab the user is not looking
    /// at, so the message says where to go and not only what is wrong.
    @ViewBuilder
    private func validationMessage(_ issues: [String]) -> some View {
        if let first = issues.first {
            Label(
                messageText(first),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(issues.joined(separator: "\n"))
            .accessibilityIdentifier("connection-form-validation")
        }
    }

    private func messageText(_ issue: String) -> String {
        guard let tab = coordinator.firstTabWithIssue, tab != coordinator.selectedTab else {
            return issue
        }
        return String(format: String(localized: "%1$@: %2$@"), tab.title, issue)
    }
}
