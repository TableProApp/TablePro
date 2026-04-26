//
//  CopilotSettingsView.swift
//  TablePro
//

import SwiftUI

struct CopilotSettingsView: View {
    @Binding var settings: CopilotSettings
    @State private var copilotService = CopilotService.shared
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Enable GitHub Copilot", isOn: $settings.enabled)
            }

            if settings.enabled {
                statusSection
                authSection
                preferencesSection
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Status Section

    private var statusSection: some View {
        Section {
            HStack {
                Text("Status")
                Spacer()
                statusBadge
            }
            if let message = copilotService.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Connection")
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch copilotService.status {
        case .stopped:
            Label("Stopped", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .starting:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Starting...")
            }
        case .running:
            Label("Running", systemImage: "circle.fill")
                .foregroundStyle(.green)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    // MARK: - Auth Section

    private var authSection: some View {
        Section {
            switch copilotService.authState {
            case .signedOut:
                Button("Sign in with GitHub") {
                    Task { await signIn() }
                }
                .disabled(copilotService.status != .running)

            case .signingIn(let userCode, _):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enter this code on GitHub:")
                    Text(userCode)
                        .font(.system(.title2, design: .monospaced))
                        .fontWeight(.bold)
                        .textSelection(.enabled)
                    Text("The code has been copied to your clipboard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(localized: "The code expires in 15 minutes."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Complete Sign In") {
                            Task { await completeSignIn() }
                        }
                        .buttonStyle(.borderedProminent)
                        Button(String(localized: "Cancel"), role: .cancel) {
                            Task { await copilotService.signOut() }
                        }
                    }
                }

            case .signedIn(let username):
                HStack {
                    Label(
                        String(format: String(localized: "Signed in as %@"), username),
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    Spacer()
                    Button("Sign Out") {
                        Task { await copilotService.signOut() }
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Account")
        }
    }

    // MARK: - Preferences Section

    private var preferencesSection: some View {
        Section {
            Toggle("Send telemetry to GitHub", isOn: $settings.telemetryEnabled)
        } header: {
            Text("Preferences")
        }
    }

    // MARK: - Actions

    private func signIn() async {
        errorMessage = nil
        do {
            try await copilotService.signIn()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func completeSignIn() async {
        errorMessage = nil
        do {
            try await copilotService.completeSignIn()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    CopilotSettingsView(settings: .constant(.default))
        .frame(width: 450, height: 500)
}
