import SwiftUI

enum ProfileEditorRoute: Identifiable {
    case newCredential
    case credential(CredentialProfile)
    case newSSH
    case ssh(SSHProfile)

    var id: String {
        switch self {
        case .newCredential: "new-credential"
        case .credential(let profile): "credential-\(profile.id.uuidString)"
        case .newSSH: "new-ssh"
        case .ssh(let profile): "ssh-\(profile.id.uuidString)"
        }
    }
}

struct ProfilesSettingsView: View {
    @ObservedObject var model: ProfilesSettingsModel
    let presentError: @MainActor (_ title: String, _ message: String) -> Void

    @State private var editor: ProfileEditorRoute?
    @State private var pendingDeletion: PendingProfileDeletion?

    var body: some View {
        Form {
            credentialSection
            sshSection
        }
        .formStyle(.grouped)
        .sheet(item: $editor) { route in
            switch route {
            case .newCredential:
                CredentialProfileEditorSheet(existingProfile: nil)
            case .credential(let profile):
                CredentialProfileEditorSheet(existingProfile: profile)
            case .newSSH:
                SSHProfileEditorView(existingProfile: nil)
            case .ssh(let profile):
                SSHProfileEditorView(existingProfile: profile)
            }
        }
        .profileDeletionAlert($pendingDeletion) { pending in
            let deleted = model.delete(pending)
            guard !deleted else { return }
            report(title: ConnectionCountCopy.deleteFailedTitle, message: ConnectionCountCopy.deleteFailedMessage)
        }
    }

    private var credentialSection: some View {
        Section {
            if model.credentialLoadFailed {
                NoticeLabel(
                    String(localized: "Credential profiles couldn't be read, so none are shown. TablePro won't save over them."),
                    severity: .error
                )
            } else {
                if model.unreadableProfileCount > 0 {
                    NoticeLabel(ConnectionCountCopy.unreadableProfiles(model.unreadableProfileCount))
                }
                if model.credentialProfiles.isEmpty {
                    if model.isLoaded {
                        Text("No credential profiles")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("credential-profiles-empty")
                    }
                } else {
                    ForEach(model.credentialProfiles) { profile in
                        credentialRow(profile)
                    }
                }
            }
            SettingsHelpRow(
                "Connections that use a profile sign in with its username and password. Edit it once to update them all."
            )
        } header: {
            Text("Credential Profiles")
        } footer: {
            SettingsSectionActions {
                Button(String(localized: "Add Credential Profile…")) {
                    editor = .newCredential
                }
                .disabled(model.credentialLoadFailed)
                .accessibilityIdentifier("add-credential-profile")
            }
        }
    }

    private var sshSection: some View {
        Section {
            if model.sshLoadFailed {
                NoticeLabel(
                    String(localized: "SSH profiles couldn't be read, so none are shown. TablePro won't save over them."),
                    severity: .error
                )
            } else if model.sshProfiles.isEmpty {
                if model.isLoaded {
                    Text("No SSH profiles")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("ssh-profiles-empty")
                }
            } else {
                ForEach(model.sshProfiles) { profile in
                    sshRow(profile)
                }
            }
            SettingsHelpRow(
                "Connections that use an SSH profile tunnel through its server. Changes reach every connection that uses it."
            )
        } header: {
            Text("SSH Profiles")
        } footer: {
            SettingsSectionActions {
                Button(String(localized: "Add SSH Profile…")) {
                    editor = .newSSH
                }
                .disabled(model.sshLoadFailed)
                .accessibilityIdentifier("add-ssh-profile")
            }
        }
    }

    private func credentialRow(_ profile: CredentialProfile) -> some View {
        SettingsRecordRow(
            title: profile.name,
            subtitle: profile.summary,
            value: usageValue(for: profile.id)
        )
        .infoButton(
            onEdit: { editor = .credential(profile) },
            onDuplicate: { duplicateCredential(profile) },
            removal: removal(of: .credential, id: profile.id, name: profile.name),
            identifier: "credential-profile-edit-\(profile.id.uuidString)"
        )
        .accessibilityIdentifier("credential-profile-row-\(profile.id.uuidString)")
    }

    private func sshRow(_ profile: SSHProfile) -> some View {
        SettingsRecordRow(
            title: profile.name,
            subtitle: profile.address,
            value: usageValue(for: profile.id)
        )
        .infoButton(
            onEdit: { editor = .ssh(profile) },
            onDuplicate: { duplicateSSH(profile) },
            removal: removal(of: .ssh, id: profile.id, name: profile.name),
            identifier: "ssh-profile-edit-\(profile.id.uuidString)"
        )
        .accessibilityIdentifier("ssh-profile-row-\(profile.id.uuidString)")
    }

    private func usageValue(for profileId: UUID) -> String? {
        model.usageCount(for: profileId).map(ConnectionCountCopy.usage)
    }

    // Unknown usage means unknown consequences, so Delete is not offered until the connections read again.
    private func removal(of kind: ProfileKind, id: UUID, name: String) -> SettingsRecordRemoval? {
        guard !model.usageUnknown else { return nil }
        return .delete {
            pendingDeletion = model.pendingDeletion(of: kind, id: id, name: name)
        }
    }

    private func duplicateCredential(_ profile: CredentialProfile) {
        guard !model.duplicateCredentialProfile(id: profile.id) else { return }
        report(title: ConnectionCountCopy.duplicateFailedTitle, message: ConnectionCountCopy.duplicateFailedMessage)
    }

    private func duplicateSSH(_ profile: SSHProfile) {
        guard !model.duplicateSSHProfile(id: profile.id) else { return }
        report(title: ConnectionCountCopy.duplicateFailedTitle, message: ConnectionCountCopy.duplicateFailedMessage)
    }

    // A turn later, so the error sheet does not race the confirmation alert that is still closing.
    private func report(title: String, message: String) {
        let presentError = presentError
        DispatchQueue.main.async {
            presentError(title, message)
        }
    }
}
