//
//  ConnectionSSHTunnelView.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 31/3/26.
//

import SwiftUI

struct ConnectionSSHTunnelView: View {
    @Binding var sshState: SSHTunnelFormState

    let databaseType: DatabaseType

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Enable SSH Tunnel"), isOn: $sshState.enabled)
                    .onChange(of: sshState.enabled) {
                        if !sshState.enabled {
                            sshState.disable()
                        }
                    }
            }

            if sshState.enabled {
                sshProfileSection

                if let profile = sshState.selectedProfile {
                    sshProfileSummarySection(profile)
                } else if sshState.profileId != nil {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color(nsColor: .systemYellow))
                            Text("Selected SSH profile no longer exists.")
                        }
                        Button("Switch to Inline Configuration") {
                            sshState.profileId = nil
                        }
                    }
                } else {
                    sshInlineFields
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - SSH Profile Section

    private var sshProfileSection: some View {
        Section(String(localized: "SSH Profile")) {
            Picker(String(localized: "Profile"), selection: $sshState.profileId) {
                Text("Inline Configuration").tag(UUID?.none)
                ForEach(sshState.profiles) { profile in
                    Text("\(profile.name) (\(profile.username)@\(profile.host))").tag(UUID?.some(profile.id))
                }
            }

            HStack(spacing: 12) {
                Button("Create New Profile...") {
                    sshState.showingCreateProfile = true
                }

                if sshState.profileId != nil {
                    Button("Edit Profile...") {
                        if let profileId = sshState.profileId {
                            sshState.editingProfile = SSHProfileStorage.shared.profile(for: profileId)
                        }
                    }
                }

                if sshState.profileId == nil && sshState.enabled && !sshState.host.isEmpty {
                    Button("Save Current as Profile...") {
                        sshState.showingSaveAsProfile = true
                    }
                }
            }
            .controlSize(.small)
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

    private func sshProfileSummarySection(_ profile: SSHProfile) -> some View {
        Section(String(localized: "Profile Settings")) {
            LabeledContent(String(localized: "Host"), value: profile.host)
            LabeledContent(String(localized: "Port"), value: profile.port.map(String.init) ?? "22")
            LabeledContent(String(localized: "Username"), value: profile.username)
            LabeledContent(String(localized: "Auth Method"), value: profile.authMethod.rawValue)
            if !profile.privateKeyPath.isEmpty {
                LabeledContent(String(localized: "Key File"), value: profile.privateKeyPath)
            }
            if !profile.jumpHosts.isEmpty {
                LabeledContent(String(localized: "Jump Hosts"), value: "\(profile.jumpHosts.count)")
            }
        }
    }

    // MARK: - SSH Inline Fields

    private var sshInlineFields: some View {
        Group {
            Section(String(localized: "Server")) {
                if !sshState.configEntries.isEmpty {
                    Picker(String(localized: "Config Host"), selection: $sshState.selectedConfigHost) {
                        Text(String(localized: "Manual")).tag("")
                        ForEach(sshState.configEntries) { entry in
                            Text(entry.displayName).tag(entry.host)
                        }
                    }
                    .onChange(of: sshState.selectedConfigHost) {
                        applySSHConfigEntry(sshState.selectedConfigHost)
                    }
                }
                if sshState.selectedConfigHost.isEmpty || sshState.configEntries.isEmpty {
                    TextField(String(localized: "SSH Host"), text: $sshState.host, prompt: Text("ssh.example.com"))
                }
                TextField(String(localized: "SSH Port"), text: $sshState.port, prompt: Text("22"))
                TextField(String(localized: "SSH User"), text: $sshState.username, prompt: Text("username"))
            }

            Section(String(localized: "Authentication")) {
                Picker(String(localized: "Method"), selection: $sshState.authMethod) {
                    ForEach(SSHAuthMethod.allCases) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                if sshState.authMethod == .password {
                    SecureField(String(localized: "Password"), text: $sshState.password)
                } else if sshState.authMethod == .sshAgent {
                    Picker(String(localized: "Agent Socket"), selection: $sshState.agentSocketOption) {
                        ForEach(SSHAgentSocketOption.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    if sshState.agentSocketOption == .custom {
                        TextField(
                            String(localized: "Custom Path"),
                            text: $sshState.customAgentSocketPath,
                            prompt: Text("/path/to/agent.sock")
                        )
                    }
                    Text("Keys are provided by the SSH agent (e.g. 1Password, ssh-agent).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if sshState.authMethod == .keyboardInteractive {
                    SecureField(String(localized: "Password"), text: $sshState.password)
                    Text(String(localized: "Password is sent via keyboard-interactive challenge-response."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent(String(localized: "Key File")) {
                        HStack {
                            TextField("", text: $sshState.privateKeyPath, prompt: Text("~/.ssh/id_rsa"))
                            Button(String(localized: "Browse")) { browseForKeyFile { sshState.privateKeyPath = $0 } }
                                .controlSize(.small)
                        }
                    }
                    SecureField(String(localized: "Passphrase"), text: $sshState.keyPassphrase)
                    if sshState.privateKeyPath.isEmpty {
                        Text(String(localized: "Auto-detects from ~/.ssh/config and default key locations."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if sshState.authMethod == .keyboardInteractive || sshState.authMethod == .password {
                Section(String(localized: "Two-Factor Authentication")) {
                    Picker(String(localized: "TOTP"), selection: $sshState.totpMode) {
                        ForEach(TOTPMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    if sshState.totpMode == .autoGenerate {
                        SecureField(String(localized: "TOTP Secret"), text: $sshState.totpSecret)
                            .help(String(localized: "Base32-encoded secret from your authenticator setup"))
                        Picker(String(localized: "Algorithm"), selection: $sshState.totpAlgorithm) {
                            ForEach(TOTPAlgorithm.allCases) { algo in
                                Text(algo.rawValue).tag(algo)
                            }
                        }
                        Picker(String(localized: "Digits"), selection: $sshState.totpDigits) {
                            Text("6").tag(6)
                            Text("8").tag(8)
                        }
                        Picker(String(localized: "Period"), selection: $sshState.totpPeriod) {
                            Text("30s").tag(30)
                            Text("60s").tag(60)
                        }
                    } else if sshState.totpMode == .promptAtConnect {
                        Text(String(localized: "You will be prompted for a verification code each time you connect."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                DisclosureGroup(String(localized: "Jump Hosts")) {
                    ForEach(sshState.jumpHosts) { jumpHost in
                        let jumpHostBinding = $sshState.jumpHosts.element(jumpHost)
                        DisclosureGroup {
                            TextField(
                                String(localized: "Host"),
                                text: jumpHostBinding.host,
                                prompt: Text("bastion.example.com")
                            )
                            HStack {
                                TextField(
                                    String(localized: "Port"),
                                    text: Binding(
                                        get: { jumpHostBinding.wrappedValue.port.map(String.init) ?? "" },
                                        set: { jumpHostBinding.wrappedValue.port = Int($0) }
                                    ),
                                    prompt: Text("22")
                                )
                                .frame(width: 80)
                                TextField(
                                    String(localized: "Username"),
                                    text: jumpHostBinding.username,
                                    prompt: Text("admin")
                                )
                            }
                            Picker(String(localized: "Auth"), selection: jumpHostBinding.authMethod) {
                                ForEach(SSHJumpAuthMethod.allCases) { method in
                                    Text(method.rawValue).tag(method)
                                }
                            }
                            if jumpHost.authMethod == .privateKey {
                                LabeledContent(String(localized: "Key File")) {
                                    HStack {
                                        TextField(
                                            "",
                                            text: jumpHostBinding.privateKeyPath,
                                            prompt: Text("~/.ssh/id_rsa")
                                        )
                                        Button(String(localized: "Browse")) {
                                            browseForKeyFile { jumpHostBinding.wrappedValue.privateKeyPath = $0 }
                                        }
                                        .controlSize(.small)
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text(
                                    jumpHost.host.isEmpty
                                        ? String(localized: "New Jump Host")
                                        : "\(jumpHost.username)@\(jumpHost.host)"
                                )
                                .foregroundStyle(jumpHost.host.isEmpty ? .secondary : .primary)
                                Spacer()
                                Button {
                                    let idToRemove = jumpHost.id
                                    withAnimation { sshState.jumpHosts.removeAll { $0.id == idToRemove } }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .frame(width: 24, height: 24)
                                        .foregroundStyle(Color(nsColor: .systemRed))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(String(localized: "Remove jump host"))
                            }
                        }
                    }
                    .onMove { indices, destination in
                        sshState.jumpHosts.move(fromOffsets: indices, toOffset: destination)
                    }

                    Button {
                        sshState.jumpHosts.append(SSHJumpHost())
                    } label: {
                        Label(String(localized: "Add Jump Host"), systemImage: "plus")
                    }

                    Text(
                        "Jump hosts are connected in order before reaching the SSH server above. Only key and agent auth are supported for jumps."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Helper Methods

    private func browseForKeyFile(onSelect: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        panel.message = String(localized: "Choose a private key file")
        panel.begin { response in
            if response == .OK, let url = panel.url {
                onSelect(url.path(percentEncoded: false))
            }
        }
    }

    private func applySSHConfigEntry(_ host: String) {
        guard !host.isEmpty else { return }
        sshState.host = host
    }
}
