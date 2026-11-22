import SwiftUI
import TableProSSHConfig
import TableProSSHTransport

// Sections, not a Form: the Network tab is the form, and the Remote File pane embeds these in it too.
struct SSHServerSections: View {
    @Binding var sshState: SSHTunnelFormState

    var body: some View {
        sshProfileSection

        if sshState.selectedProfile == nil, sshState.profileId != nil {
            Section {
                NoticeLabel(String(localized: "Selected SSH profile no longer exists."))
                Button(String(localized: "Switch to Inline Configuration")) {
                    sshState.profileId = nil
                }
            }
        } else if sshState.selectedProfile == nil {
            SSHServerFields(
                draft: $sshState.server,
                configEntries: sshState.configEntries,
                identifierPrefix: "connection-form-ssh",
                savedSecrets: sshState.savedSecrets
            )
        }
    }

    private var sshProfileSection: some View {
        Section(String(localized: "Profile")) {
            Picker(String(localized: "Profile"), selection: $sshState.profileId) {
                Text("Inline Configuration").tag(UUID?.none)
                ForEach(sshState.profiles) { profile in
                    Text(verbatim: "\(profile.name) (\(profile.address))").tag(UUID?.some(profile.id))
                }
            }

            HStack(spacing: 12) {
                Button("Create New Profile…") {
                    sshState.showingCreateProfile = true
                }

                if sshState.profileId != nil {
                    Button("Edit Profile…") {
                        if let profileId = sshState.profileId {
                            sshState.editingProfile = SSHProfileStorage.shared.profile(for: profileId)
                        }
                    }
                }

                if sshState.profileId == nil && sshState.enabled && !sshState.host.isEmpty {
                    Button("Save Current as Profile…") {
                        sshState.showingSaveAsProfile = true
                    }
                }
            }
            .controlSize(.small)

            if let profile = sshState.selectedProfile {
                DisclosureGroup(String(localized: "Profile Details")) {
                    LabeledContent(String(localized: "Host"), value: profile.host)
                    LabeledContent(String(localized: "Port")) {
                        Text(verbatim: SettingsFormat.identifier(profile.port ?? 22))
                    }
                    LabeledContent(String(localized: "Username"), value: profile.username)
                    LabeledContent(String(localized: "Authentication Method"), value: profile.authMethod.displayName)
                    if !profile.privateKeyPath.isEmpty {
                        LabeledContent(
                            profile.authMethod == .sshAgent
                                ? String(localized: "Identity File")
                                : String(localized: "Key File"),
                            value: profile.privateKeyPath
                        )
                    }
                    if !profile.jumpHosts.isEmpty {
                        LabeledContent(String(localized: "Jump Hosts")) {
                            Text(profile.jumpHosts.count, format: .number)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $sshState.showingCreateProfile) {
            SSHProfileEditorView(existingProfile: nil, onSave: { _ in
                reloadProfiles()
            })
        }
        .sheet(item: $sshState.editingProfile) { profile in
            SSHProfileEditorView(existingProfile: profile, onSave: { _ in
                reloadProfiles()
            }, onDelete: {
                reloadProfiles()
            })
        }
        .sheet(isPresented: $sshState.showingSaveAsProfile) {
            SSHProfileEditorView(
                existingProfile: buildProfileFromInlineConfig(),
                initialPassword: sshState.password,
                initialKeyPassphrase: sshState.keyPassphrase,
                initialTOTPSecret: sshState.totpSecret,
                onSave: { savedProfile in
                    sshState.profileId = savedProfile.id
                    reloadProfiles()
                }
            )
        }
    }

    private func reloadProfiles() {
        sshState.profiles = SSHProfileStorage.shared.loadProfiles()
        if let id = sshState.profileId,
           !SSHProfileStorage.shared.lastLoadFailed,
           !sshState.profiles.contains(where: { $0.id == id }) {
            sshState.profileId = nil
        }
    }

    private func buildProfileFromInlineConfig() -> SSHProfile {
        SSHProfile(
            name: "",
            host: sshState.host,
            port: Int(sshState.port),
            username: sshState.username,
            authMethod: sshState.authMethod,
            privateKeyPath: sshState.privateKeyPath,
            agentSocketPath: sshState.resolvedAgentSocketPath,
            jumpHosts: sshState.jumpHosts,
            totpMode: sshState.totpMode,
            totpAlgorithm: sshState.totpAlgorithm,
            totpDigits: sshState.totpDigits,
            totpPeriod: sshState.totpPeriod
        )
    }
}
