//
//  LicenseActivationForm.swift
//  TablePro
//

import SwiftUI

/// The key field, the Activate button and the one error path, shared by every surface that
/// activates a license.
///
/// Only the logic is shared, not the chrome. The sheet is a small utility dialog and the settings
/// pane is a full-width landing state, so each composes its own surroundings and this owns what
/// actually drifted when there were two copies: the field, the in-flight state, and how a failure
/// is worded.
struct LicenseActivationForm: View {
    /// Called after a successful activation, so a sheet can dismiss and a pane can do nothing.
    var onActivated: () -> Void = {}

    @State private var codeOrKey = ""
    @State private var isActivating = false
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    private var trimmed: String {
        codeOrKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(String(localized: "License key or invite code"), text: $codeOrKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .disableAutocorrection(true)
                .focused($fieldFocused)
                .onSubmit { activate() }
                .accessibilityIdentifier("license-key-field")

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("license-activation-error")
            }

            HStack(spacing: 10) {
                Button(String(localized: "Activate")) { activate() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || isActivating)
                    .accessibilityIdentifier("license-activate-button")

                if isActivating {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .onAppear { fieldFocused = true }
    }

    private func activate() {
        guard !trimmed.isEmpty, !isActivating else { return }

        Task {
            errorMessage = nil
            isActivating = true
            defer { isActivating = false }

            do {
                try await LicenseManager.shared.activate(codeOrKey: trimmed)
                codeOrKey = ""
                onActivated()
            } catch {
                errorMessage = (error as? LicenseError)?.friendlyDescription ?? error.localizedDescription
            }
        }
    }
}

#Preview {
    LicenseActivationForm()
        .padding()
        .frame(width: 380)
}
