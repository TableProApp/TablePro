//
//  PasswordSourceEditor.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// Where the connection takes its password from, and the one field the chosen source needs.
struct PasswordSourceEditor: View {
    let type: DatabaseType
    @Binding var draft: PasswordSourceDraft
    @Binding var password: String
    @Binding var additionalFieldValues: [String: String]
    let context: PasswordCommandTemplate.Context

    @State private var settings = AppSettingsManager.shared
    @State private var probe = PasswordSourceProbe()

    private var isApiOnly: Bool {
        PluginManager.shared.connectionMode(for: type) == .apiOnly
    }

    private var secretLabel: String {
        isApiOnly ? String(localized: "API Token") : String(localized: "Password")
    }

    var body: some View {
        Picker(selection: $draft.mode) {
            ForEach(PasswordSourceMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        } label: {
            Text(isApiOnly ? String(localized: "API token:") : String(localized: "Password:"))
        }
        .accessibilityIdentifier("connection-form-password-mode")
        .onChange(of: draft.mode) { _, newValue in
            guard newValue != .keychain else { return }
            password = ""
            if additionalFieldValues["usePgpass"] == "true" {
                additionalFieldValues["usePgpass"] = ""
            }
        }

        modeFields
        commandPreview
        probeRow
    }

    @ViewBuilder
    private var modeFields: some View {
        switch draft.mode {
        case .keychain:
            SecureField(secretLabel, text: $password)
                .accessibilityIdentifier("connection-form-password")
        case .prompt:
            EmptyView()
        case .sharedTemplate:
            sharedTemplateCaption
        case .command:
            TextField(String(localized: "Command"), text: $draft.command, axis: .vertical)
                .lineLimit(1 ... 4)
                .font(.system(.body, design: .monospaced))
                .accessibilityIdentifier("connection-form-password-command")
            placeholderCaption
        case .onePassword:
            TextField(String(localized: "Secret reference"), text: $draft.onePasswordReference)
                .accessibilityIdentifier("connection-form-password-op-reference")
            caption(String(localized: "Runs the 1Password CLI. Example: op://Vault/Database/password"))
        case .vault:
            TextField(String(localized: "Secret path"), text: $draft.vaultPath)
                .accessibilityIdentifier("connection-form-password-vault-path")
            TextField(String(localized: "Field"), text: $draft.vaultField)
                .accessibilityIdentifier("connection-form-password-vault-field")
            caption(String(localized: "Runs the Vault CLI against the address and token in your environment."))
        case .awsSecretsManager:
            TextField(String(localized: "Secret ID"), text: $draft.awsSecretId)
                .accessibilityIdentifier("connection-form-password-aws-secret")
            TextField(String(localized: "JSON key (optional)"), text: $draft.awsJsonKey)
                .accessibilityIdentifier("connection-form-password-aws-key")
            TextField(String(localized: "Profile (optional)"), text: $draft.awsProfile)
                .accessibilityIdentifier("connection-form-password-aws-profile")
            TextField(String(localized: "Region (optional)"), text: $draft.awsRegion)
                .accessibilityIdentifier("connection-form-password-aws-region")
            caption(String(localized: "Name a profile to reach an account other than the one your environment selects."))
        case .file:
            TextField(String(localized: "File path"), text: $draft.filePath)
                .accessibilityIdentifier("connection-form-password-file")
            caption(String(localized: "The whole file is the password, minus surrounding whitespace."))
        case .environment:
            TextField(String(localized: "Variable name"), text: $draft.environmentVariable)
                .accessibilityIdentifier("connection-form-password-env")
            caption(String(localized: """
                Read from TablePro's own environment. An app launched from the Dock does not \
                inherit your shell exports.
                """))
        }
    }

    @ViewBuilder
    private var sharedTemplateCaption: some View {
        if settings.secretManager.hasDefaultCommand {
            caption(String(localized: "Runs the command set in Settings > General > Secret Manager."))
        } else {
            Label(
                String(localized: "No shared command is set yet. Add one in Settings > General > Secret Manager."),
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var placeholderCaption: some View {
        caption(
            String(
                format: String(localized: "Prints the password on stdout. Placeholders: %@"),
                PasswordCommandTemplate.placeholders.map(\.token).joined(separator: ", ")
            )
        )
    }

    /// The command as it will actually run, so a template the user cannot see filled in is not
    /// something they have to connect to find out about.
    @ViewBuilder
    private var commandPreview: some View {
        if let command = previewCommand {
            VStack(alignment: .leading, spacing: 2) {
                Text("Runs:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .accessibilityIdentifier("connection-form-password-command-preview")
            }
        }
    }

    private var sharedTemplate: String {
        settings.secretManager.trimmedDefaultCommand
    }

    private var previewCommand: String? {
        guard let source = draft.passwordSource else { return nil }
        return PasswordSourceResolver.effectiveCommand(
            for: source,
            context: context,
            sharedTemplate: sharedTemplate
        )
    }

    @ViewBuilder
    private var probeRow: some View {
        if draft.mode.isExternal {
            HStack(spacing: 8) {
                Button(String(localized: "Fetch Now")) {
                    probe.run(
                        source: draft.passwordSource,
                        context: context,
                        sharedTemplate: sharedTemplate
                    )
                }
                .disabled(draft.passwordSource == nil || probe.isRunning)
                .accessibilityIdentifier("connection-form-password-fetch")

                if probe.isRunning {
                    ProgressView().controlSize(.small)
                }
                if let outcome = probe.outcome {
                    Label(outcome.message, systemImage: outcome.isSuccess ? "checkmark.circle" : "xmark.circle")
                        .font(.caption)
                        .foregroundStyle(outcome.isSuccess ? Color.green : Color.red)
                        .accessibilityIdentifier("connection-form-password-fetch-result")
                }
            }
            .onChange(of: draft) { _, _ in probe.reset() }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
