//
//  ConnectionSSHTunnelView.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 31/3/26.
//

import SwiftUI

struct ConnectionSSHTunnelView: View {
    @Binding var sshEnabled: Bool
    @Binding var sshProfileId: UUID?
    @Binding var sshProfiles: [SSHProfile]
    @Binding var showingCreateProfile: Bool
    @Binding var editingProfile: SSHProfile?
    @Binding var showingSaveAsProfile: Bool
    @Binding var sshHost: String
    @Binding var sshPort: String
    @Binding var sshUsername: String
    @Binding var sshPassword: String
    @Binding var sshAuthMethod: SSHAuthMethod
    @Binding var sshPrivateKeyPath: String
    @Binding var sshAgentSocketOption: SSHAgentSocketOption
    @Binding var customSSHAgentSocketPath: String
    @Binding var keyPassphrase: String
    @Binding var sshConfigEntries: [SSHConfigEntry]
    @Binding var selectedSSHConfigHost: String
    @Binding var jumpHosts: [SSHJumpHost]
    @Binding var totpMode: TOTPMode
    @Binding var totpSecret: String
    @Binding var totpAlgorithm: TOTPAlgorithm
    @Binding var totpDigits: Int
    @Binding var totpPeriod: Int

    let databaseType: DatabaseType

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Enable SSH Tunnel"), isOn: $sshEnabled)
            }

            if sshEnabled {
                sshProfileSection

                if let profile = selectedSSHProfile {
                    sshProfileSummarySection(profile)
                } else if sshProfileId != nil {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text("Selected SSH profile no longer exists.")
                        }
                        Button("Switch to Inline Configuration") {
                            sshProfileId = nil
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
            Picker(String(localized: "Profile"), selection: $sshProfileId) {
                Text("Inline Configuration").tag(UUID?.none)
                ForEach(sshProfiles) { profile in
                    Text("\(profile.name) (\(profile.username)@\(profile.host))").tag(UUID?.some(profile.id))
                }
            }

            HStack(spacing: 12) {
                Button("Create New Profile...") {
                    showingCreateProfile = true
                }

                if sshProfileId != nil {
                    Button("Edit Profile...") {
                        if let profileId = sshProfileId {
                            editingProfile = SSHProfileStorage.shared.profile(for: profileId)
                        }
                    }
                }

                if sshProfileId == nil && sshEnabled && !sshHost.isEmpty {
                    Button("Save Current as Profile...") {
                        showingSaveAsProfile = true
                    }
                }
            }
            .controlSize(.small)
        }
        .sheet(isPresented: $showingCreateProfile) {
            SSHProfileEditorView(existingProfile: nil, onSave: { _ in
                reloadProfiles()
            })
        }
        .sheet(item: $editingProfile) { profile in
            SSHProfileEditorView(existingProfile: profile, onSave: { _ in
                reloadProfiles()
            }, onDelete: {
                reloadProfiles()
            })
        }
        .sheet(isPresented: $showingSaveAsProfile) {
            SSHProfileEditorView(
                existingProfile: buildProfileFromInlineConfig(),
                initialPassword: sshPassword,
                initialKeyPassphrase: keyPassphrase,
                initialTOTPSecret: totpSecret,
                onSave: { savedProfile in
                    sshProfileId = savedProfile.id
                    reloadProfiles()
                }
            )
        }
    }

    private var selectedSSHProfile: SSHProfile? {
        guard let id = sshProfileId else { return nil }
        return sshProfiles.first { $0.id == id }
    }

    private func reloadProfiles() {
        sshProfiles = SSHProfileStorage.shared.loadProfiles()
        if let id = sshProfileId,
           !SSHProfileStorage.shared.lastLoadFailed,
           !sshProfiles.contains(where: { $0.id == id }) {
            sshProfileId = nil
        }
    }

    private func buildProfileFromInlineConfig() -> SSHProfile {
        SSHProfile(
            name: "",
            host: sshHost,
            port: Int(sshPort) ?? 22,
            username: sshUsername,
            authMethod: sshAuthMethod,
            privateKeyPath: sshPrivateKeyPath,
            useSSHConfig: !selectedSSHConfigHost.isEmpty,
            agentSocketPath: sshAgentSocketOption.resolvedPath(customPath: customSSHAgentSocketPath),
            jumpHosts: jumpHosts,
            totpMode: totpMode,
            totpAlgorithm: totpAlgorithm,
            totpDigits: totpDigits,
            totpPeriod: totpPeriod
        )
    }

    private func sshProfileSummarySection(_ profile: SSHProfile) -> some View {
        Section(String(localized: "Profile Settings")) {
            LabeledContent(String(localized: "Host"), value: profile.host)
            LabeledContent(String(localized: "Port"), value: String(profile.port))
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
                if !sshConfigEntries.isEmpty {
                    Picker(String(localized: "Config Host"), selection: $selectedSSHConfigHost) {
                        Text(String(localized: "Manual")).tag("")
                        ForEach(sshConfigEntries) { entry in
                            Text(entry.displayName).tag(entry.host)
                        }
                    }
                    .onChange(of: selectedSSHConfigHost) {
                        applySSHConfigEntry(selectedSSHConfigHost)
                    }
                }
                if selectedSSHConfigHost.isEmpty || sshConfigEntries.isEmpty {
                    TextField(String(localized: "SSH Host"), text: $sshHost, prompt: Text("ssh.example.com"))
                }
                TextField(String(localized: "SSH Port"), text: $sshPort, prompt: Text("22"))
                TextField(String(localized: "SSH User"), text: $sshUsername, prompt: Text("username"))
            }

            Section(String(localized: "Authentication")) {
                Picker(String(localized: "Method"), selection: $sshAuthMethod) {
                    ForEach(SSHAuthMethod.allCases) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                if sshAuthMethod == .password {
                    SecureField(String(localized: "Password"), text: $sshPassword)
                } else if sshAuthMethod == .sshAgent {
                    Picker("Agent Socket", selection: $sshAgentSocketOption) {
                        ForEach(SSHAgentSocketOption.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    if sshAgentSocketOption == .custom {
                        TextField("Custom Path", text: $customSSHAgentSocketPath, prompt: Text("/path/to/agent.sock"))
                    }
                    Text("Keys are provided by the SSH agent (e.g. 1Password, ssh-agent).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if sshAuthMethod == .keyboardInteractive {
                    SecureField(String(localized: "Password"), text: $sshPassword)
                    Text(String(localized: "Password is sent via keyboard-interactive challenge-response."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent(String(localized: "Key File")) {
                        HStack {
                            TextField("", text: $sshPrivateKeyPath, prompt: Text("~/.ssh/id_rsa"))
                            Button(String(localized: "Browse")) { browseForPrivateKey() }
                                .controlSize(.small)
                        }
                    }
                    SecureField(String(localized: "Passphrase"), text: $keyPassphrase)
                }
            }

            if sshAuthMethod == .keyboardInteractive || sshAuthMethod == .password {
                Section(String(localized: "Two-Factor Authentication")) {
                    Picker(String(localized: "TOTP"), selection: $totpMode) {
                        ForEach(TOTPMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    if totpMode == .autoGenerate {
                        SecureField(String(localized: "TOTP Secret"), text: $totpSecret)
                            .help(String(localized: "Base32-encoded secret from your authenticator setup"))
                        Picker(String(localized: "Algorithm"), selection: $totpAlgorithm) {
                            ForEach(TOTPAlgorithm.allCases) { algo in
                                Text(algo.rawValue).tag(algo)
                            }
                        }
                        Picker(String(localized: "Digits"), selection: $totpDigits) {
                            Text("6").tag(6)
                            Text("8").tag(8)
                        }
                        Picker(String(localized: "Period"), selection: $totpPeriod) {
                            Text("30s").tag(30)
                            Text("60s").tag(60)
                        }
                    } else if totpMode == .promptAtConnect {
                        Text(String(localized: "You will be prompted for a verification code each time you connect."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                DisclosureGroup(String(localized: "Jump Hosts")) {
                    ForEach($jumpHosts) { $jumpHost in
                        DisclosureGroup {
                            TextField(String(localized: "Host"), text: $jumpHost.host, prompt: Text("bastion.example.com"))
                            HStack {
                                TextField(
                                    String(localized: "Port"),
                                    text: Binding(
                                        get: { String(jumpHost.port) },
                                        set: { jumpHost.port = Int($0) ?? 22 }
                                    ),
                                    prompt: Text("22")
                                )
                                .frame(width: 80)
                                TextField(String(localized: "Username"), text: $jumpHost.username, prompt: Text("admin"))
                            }
                            Picker(String(localized: "Auth"), selection: $jumpHost.authMethod) {
                                ForEach(SSHJumpAuthMethod.allCases) { method in
                                    Text(method.rawValue).tag(method)
                                }
                            }
                            if jumpHost.authMethod == .privateKey {
                                LabeledContent(String(localized: "Key File")) {
                                    HStack {
                                        TextField("", text: $jumpHost.privateKeyPath, prompt: Text("~/.ssh/id_rsa"))
                                        Button(String(localized: "Browse")) {
                                            browseForJumpHostKey(jumpHost: $jumpHost)
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
                                    withAnimation { jumpHosts.removeAll { $0.id == idToRemove } }
                                } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .onMove { indices, destination in
                        jumpHosts.move(fromOffsets: indices, toOffset: destination)
                    }

                    Button {
                        jumpHosts.append(SSHJumpHost())
                    } label: {
                        Label(String(localized: "Add Jump Host"), systemImage: "plus")
                    }

                    Text("Jump hosts are connected in order before reaching the SSH server above. Only key and agent auth are supported for jumps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Helper Methods

    private func browseForPrivateKey() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".ssh")
        panel.showsHiddenFiles = true

        panel.begin { response in
            if response == .OK, let url = panel.url {
                sshPrivateKeyPath = url.path(percentEncoded: false)
            }
        }
    }

    private func browseForJumpHostKey(jumpHost: Binding<SSHJumpHost>) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".ssh")
        panel.showsHiddenFiles = true

        panel.begin { response in
            if response == .OK, let url = panel.url {
                jumpHost.wrappedValue.privateKeyPath = url.path(percentEncoded: false)
            }
        }
    }

    private func applySSHConfigEntry(_ host: String) {
        guard let entry = sshConfigEntries.first(where: { $0.host == host }) else {
            return
        }

        sshHost = entry.hostname ?? entry.host
        if let port = entry.port {
            sshPort = String(port)
        }
        if let user = entry.user {
            sshUsername = user
        }
        if let agentPath = entry.identityAgent {
            applySSHAgentSocketPath(agentPath)
            sshAuthMethod = .sshAgent
        } else if let keyPath = entry.identityFile {
            sshPrivateKeyPath = keyPath
            sshAuthMethod = .privateKey
        }
        if let proxyJump = entry.proxyJump {
            jumpHosts = SSHConfigParser.parseProxyJump(proxyJump)
        }
    }

    private func applySSHAgentSocketPath(_ socketPath: String) {
        let option = SSHAgentSocketOption(socketPath: socketPath)
        sshAgentSocketOption = option

        if option == .custom {
            customSSHAgentSocketPath = socketPath.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            customSSHAgentSocketPath = ""
        }
    }
}
