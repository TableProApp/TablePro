//
//  CredentialProfilePicker.swift
//  TablePro
//

import SwiftUI

/// Picks the credentials a connection signs in with: its own, or a named profile.
///
/// The inline item comes first so the menu is never empty and always has a useful default, which is
/// what a pop-up button is for. Managing the profiles is a separate surface rather than another
/// sheet on this window, so the same list serves every connection.
struct CredentialProfilePicker: View {
    @Bindable var auth: AuthPaneViewModel

    var body: some View {
        Picker(String(localized: "Credentials"), selection: $auth.credentialMode) {
            Text(String(localized: "Enter Below")).tag(CredentialMode.inline)
            ForEach(auth.credentialProfiles) { profile in
                Text(profile.name).tag(CredentialMode.profile(id: profile.id))
            }
            /// A selection with no matching tag renders as no selection at all, so a connection
            /// pointing at a profile this Mac does not have would read as if nothing were chosen.
            if auth.credentialProfileIsMissing {
                Text(String(localized: "Missing Profile")).tag(auth.credentialMode)
            }
        }
        .accessibilityIdentifier("connection-form-credential-profile")

        if auth.credentialProfileIsMissing {
            Label(
                String(localized: "This connection uses a credential profile that isn't on this Mac."),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.yellow)
            Button(String(localized: "Enter Credentials Here")) {
                auth.credentialMode = .inline
            }
            .controlSize(.small)
            .accessibilityIdentifier("credential-profile-relink")
        } else if let profile = auth.selectedCredentialProfile {
            LabeledContent(String(localized: "Username"), value: displayUsername(profile))
            LabeledContent(String(localized: "Password"), value: profile.passwordMode.displayName)
        }

        HStack(spacing: 12) {
            Button(String(localized: "Manage Profiles…")) {
                WindowOpener.shared.openSettings(tab: .profiles)
            }
            .accessibilityIdentifier("manage-credential-profiles")
            if !auth.usesCredentialProfile, auth.hasPromotableCredentials {
                Button(String(localized: "Save These as a Profile…")) {
                    auth.isSavingCredentialsAsProfile = true
                }
                .accessibilityIdentifier("save-credentials-as-profile")
            }
        }
        .controlSize(.small)
        /// Managing profiles happens in a different window, and this form can save afterwards.
        /// Without this, deleting the selected profile in Settings converts the connection to
        /// inline and copies its password across, and then a Save here writes the dead profile id
        /// back and deletes that copy.
        .onReceive(NotificationCenter.default.publisher(for: .credentialProfilesDidChange)) { _ in
            auth.reconcileCredentialProfiles()
        }
        .sheet(isPresented: $auth.isSavingCredentialsAsProfile) {
            CredentialProfileEditorSheet(
                existingProfile: auth.profileFromCurrentCredentials(),
                initialPassword: auth.password,
                initialDatabaseType: auth.coordinator?.value?.network.type,
                onSave: { saved in
                    auth.loadCredentialProfiles()
                    auth.credentialMode = .profile(id: saved.id)
                }
            )
        }
    }

    private func displayUsername(_ profile: CredentialProfile) -> String {
        let trimmed = profile.username.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? String(localized: "None") : trimmed
    }
}
