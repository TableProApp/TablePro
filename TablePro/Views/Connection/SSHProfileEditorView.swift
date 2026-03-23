//
//  SSHProfileEditorView.swift
//  TablePro
//

import SwiftUI

struct SSHProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let existingProfile: SSHProfile?
    var initialPassword: String?
    var initialKeyPassphrase: String?
    var initialTOTPSecret: String?
    var onSave: ((SSHProfile) -> Void)?
    var onDelete: (() -> Void)?

    // Profile identity
    @State private var profileName: String = ""

    // Server
    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var username: String = ""

    // Authentication
    @State private var authMethod: SSHAuthMethod = .password
    @State private var sshPassword: String = ""
    @State private var privateKeyPath: String = ""
    @State private var keyPassphrase: String = ""
    @State private var agentSocketOption: SSHAgentSocketOption = .systemDefault
    @State private var customAgentSocketPath: String = ""

    // TOTP
    @State private var totpMode: TOTPMode = .none
    @State private var totpSecret: String = ""
    @State private var totpAlgorithm: TOTPAlgorithm = .sha1
    @State private var totpDigits: Int = 6
    @State private var totpPeriod: Int = 30

    // Jump hosts
    @State private var jumpHosts: [SSHJumpHost] = []

    // SSH config auto-fill
    @State private var sshConfigEntries: [SSHConfigEntry] = []
    @State private var selectedSSHConfigHost: String = ""

    // Deletion
    @State private var showingDeleteConfirmation = false
    @State private var connectionsUsingProfile = 0
    @State private var isTesting = false
    @State private var testSucceeded = false
    @State private var testTask: Task<Void, Never>?

    private var isStoredProfile: Bool {
        guard let profile = existingProfile else { return false }
        return SSHProfileStorage.shared.profile(for: profile.id) != nil
    }

    private var isValid: Bool {
        let nameValid = !profileName.trimmingCharacters(in: .whitespaces).isEmpty
        let hostValid = !host.trimmingCharacters(in: .whitespaces).isEmpty
        let portValid = port.isEmpty || (Int(port).map { (1...65_535).contains($0) } ?? false)
        let authValid = authMethod == .password || authMethod == .sshAgent
            || authMethod == .keyboardInteractive || !privateKeyPath.isEmpty
        let jumpValid = jumpHosts.allSatisfy(\.isValid)
        return nameValid && hostValid && portValid && authValid && jumpValid
    }

    private var resolvedAgentSocketPath: String {
        agentSocketOption.resolvedPath(customPath: customAgentSocketPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(String(localized: "Profile")) {
                    TextField(String(localized: "Name"), text: $profileName, prompt: Text("My Server"))
                }

                serverSection
                authenticationSection

                if authMethod == .keyboardInteractive || authMethod == .password {
                    totpSection
                }

                jumpHostsSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            bottomBar
        }
        .frame(minWidth: 480, minHeight: 500)
        .onAppear {
            sshConfigEntries = SSHConfigParser.parse()
            loadExistingProfile()
        }
        .onChange(of: host) { _, _ in testSucceeded = false }
        .onChange(of: port) { _, _ in testSucceeded = false }
        .onChange(of: username) { _, _ in testSucceeded = false }
        .onChange(of: authMethod) { _, _ in testSucceeded = false }
        .onChange(of: sshPassword) { _, _ in testSucceeded = false }
        .onChange(of: privateKeyPath) { _, _ in testSucceeded = false }
        .onChange(of: keyPassphrase) { _, _ in testSucceeded = false }
        .onChange(of: agentSocketOption) { _, _ in testSucceeded = false }
        .onChange(of: customAgentSocketPath) { _, _ in testSucceeded = false }
        .onChange(of: totpMode) { _, _ in testSucceeded = false }
        .onChange(of: totpSecret) { _, _ in testSucceeded = false }
        .onChange(of: jumpHosts) { _, _ in testSucceeded = false }
        .onDisappear {
            testTask?.cancel()
        }
    }

    // MARK: - Server Section

    private var serverSection: some View {
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
                TextField(String(localized: "SSH Host"), text: $host, prompt: Text("ssh.example.com"))
            }
            TextField(String(localized: "SSH Port"), text: $port, prompt: Text("22"))
            TextField(String(localized: "SSH User"), text: $username, prompt: Text("username"))
        }
    }

    // MARK: - Authentication Section

    private var authenticationSection: some View {
        Section(String(localized: "Authentication")) {
            Picker(String(localized: "Method"), selection: $authMethod) {
                ForEach(SSHAuthMethod.allCases) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            if authMethod == .password {
                SecureField(String(localized: "Password"), text: $sshPassword)
            } else if authMethod == .sshAgent {
                Picker("Agent Socket", selection: $agentSocketOption) {
                    ForEach(SSHAgentSocketOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                if agentSocketOption == .custom {
                    TextField("Custom Path", text: $customAgentSocketPath, prompt: Text("/path/to/agent.sock"))
                }
                Text("Keys are provided by the SSH agent (e.g. 1Password, ssh-agent).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if authMethod == .keyboardInteractive {
                SecureField(String(localized: "Password"), text: $sshPassword)
                Text(String(localized: "Password is sent via keyboard-interactive challenge-response."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent(String(localized: "Key File")) {
                    HStack {
                        TextField("", text: $privateKeyPath, prompt: Text("~/.ssh/id_rsa"))
                        Button(String(localized: "Browse")) { browseForPrivateKey() }
                            .controlSize(.small)
                    }
                }
                SecureField(String(localized: "Passphrase"), text: $keyPassphrase)
            }
        }
    }

    // MARK: - TOTP Section

    private var totpSection: some View {
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

    // MARK: - Jump Hosts Section

    private var jumpHostsSection: some View {
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

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            if isStoredProfile {
                Button(role: .destructive) {
                    connectionsUsingProfile = ConnectionStorage.shared.loadConnections()
                        .filter { $0.sshProfileId == existingProfile?.id }.count
                    showingDeleteConfirmation = true
                } label: {
                    Text("Delete Profile")
                }
                .confirmationDialog(
                    "Delete SSH Profile?",
                    isPresented: $showingDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) { deleteProfile() }
                } message: {
                    if connectionsUsingProfile > 0 {
                        Text("\(connectionsUsingProfile) connection(s) use this profile. They will fall back to no SSH tunnel.")
                    } else {
                        Text("This profile will be permanently deleted.")
                    }
                }
            }

            Button(action: testSSHConnection) {
                HStack(spacing: 6) {
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: testSucceeded ? "checkmark.circle.fill" : "bolt.horizontal")
                            .foregroundStyle(testSucceeded ? .green : .secondary)
                    }
                    Text("Test Connection")
                }
            }
            .disabled(isTesting || !isValid)

            Spacer()

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button(isStoredProfile ? "Save" : "Create") { saveProfile() }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
        .padding()
    }

    // MARK: - Actions

    private func loadExistingProfile() {
        guard let profile = existingProfile else { return }
        profileName = profile.name
        host = profile.host
        port = String(profile.port)
        username = profile.username
        authMethod = profile.authMethod
        privateKeyPath = profile.privateKeyPath
        jumpHosts = profile.jumpHosts
        totpMode = profile.totpMode
        totpAlgorithm = profile.totpAlgorithm
        totpDigits = profile.totpDigits
        totpPeriod = profile.totpPeriod

        let option = SSHAgentSocketOption(socketPath: profile.agentSocketPath)
        agentSocketOption = option
        if option == .custom {
            customAgentSocketPath = profile.agentSocketPath
        }

        // Load secrets from Keychain, falling back to initial values (e.g. from "Save as Profile")
        sshPassword = SSHProfileStorage.shared.loadSSHPassword(for: profile.id) ?? initialPassword ?? ""
        keyPassphrase = SSHProfileStorage.shared.loadKeyPassphrase(for: profile.id) ?? initialKeyPassphrase ?? ""
        totpSecret = SSHProfileStorage.shared.loadTOTPSecret(for: profile.id) ?? initialTOTPSecret ?? ""
    }

    private func saveProfile() {
        let profileId = existingProfile?.id ?? UUID()

        let profile = SSHProfile(
            id: profileId,
            name: profileName.trimmingCharacters(in: .whitespaces),
            host: host,
            port: Int(port) ?? 22,
            username: username,
            authMethod: authMethod,
            privateKeyPath: privateKeyPath,
            useSSHConfig: !selectedSSHConfigHost.isEmpty,
            agentSocketPath: resolvedAgentSocketPath,
            jumpHosts: jumpHosts,
            totpMode: totpMode,
            totpAlgorithm: totpAlgorithm,
            totpDigits: totpDigits,
            totpPeriod: totpPeriod
        )

        if isStoredProfile {
            SSHProfileStorage.shared.updateProfile(profile)
        } else {
            SSHProfileStorage.shared.addProfile(profile)
        }

        // Save secrets to Keychain
        if (authMethod == .password || authMethod == .keyboardInteractive) && !sshPassword.isEmpty {
            SSHProfileStorage.shared.saveSSHPassword(sshPassword, for: profileId)
        } else {
            SSHProfileStorage.shared.deleteSSHPassword(for: profileId)
        }

        if authMethod == .privateKey && !keyPassphrase.isEmpty {
            SSHProfileStorage.shared.saveKeyPassphrase(keyPassphrase, for: profileId)
        } else {
            SSHProfileStorage.shared.deleteKeyPassphrase(for: profileId)
        }

        if totpMode == .autoGenerate && !totpSecret.isEmpty {
            SSHProfileStorage.shared.saveTOTPSecret(totpSecret, for: profileId)
        } else {
            SSHProfileStorage.shared.deleteTOTPSecret(for: profileId)
        }

        onSave?(profile)
        dismiss()
    }

    private func testSSHConnection() {
        isTesting = true
        testSucceeded = false
        let window = NSApp.keyWindow

        // Use .none for promptAtConnect during test — avoids showing an uncontextualized
        // TOTP modal. The SSH connection is still tested (auth without TOTP).
        let testTotpMode: TOTPMode = totpMode == .promptAtConnect ? .none : totpMode

        let config = SSHConfiguration(
            enabled: true,
            host: host,
            port: Int(port) ?? 22,
            username: username,
            authMethod: authMethod,
            privateKeyPath: privateKeyPath,
            agentSocketPath: resolvedAgentSocketPath,
            jumpHosts: jumpHosts,
            totpMode: testTotpMode,
            totpAlgorithm: totpAlgorithm,
            totpDigits: totpDigits,
            totpPeriod: totpPeriod
        )

        let credentials = SSHTunnelCredentials(
            sshPassword: sshPassword.isEmpty ? nil : sshPassword,
            keyPassphrase: keyPassphrase.isEmpty ? nil : keyPassphrase,
            totpSecret: totpSecret.isEmpty ? nil : totpSecret,
            totpProvider: nil
        )

        testTask = Task {
            do {
                try await SSHTunnelManager.shared.testSSHProfile(
                    config: config,
                    credentials: credentials
                )
                await MainActor.run {
                    isTesting = false
                    testSucceeded = true
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isTesting = false
                    testSucceeded = false
                    AlertHelper.showErrorSheet(
                        title: String(localized: "SSH Connection Test Failed"),
                        message: error.localizedDescription,
                        window: window
                    )
                }
            }
        }
    }

    private func deleteProfile() {
        guard let profile = existingProfile else { return }
        SSHProfileStorage.shared.deleteProfile(profile)
        onDelete?()
        dismiss()
    }

    // MARK: - SSH Config Helpers

    private func applySSHConfigEntry(_ configHost: String) {
        guard let entry = sshConfigEntries.first(where: { $0.host == configHost }) else { return }

        host = entry.hostname ?? entry.host
        if let entryPort = entry.port {
            port = String(entryPort)
        }
        if let user = entry.user {
            username = user
        }
        if let agentPath = entry.identityAgent {
            let option = SSHAgentSocketOption(socketPath: agentPath)
            agentSocketOption = option
            if option == .custom {
                customAgentSocketPath = agentPath.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            authMethod = .sshAgent
        } else if let keyPath = entry.identityFile {
            privateKeyPath = keyPath
            authMethod = .privateKey
        }
        if let proxyJump = entry.proxyJump {
            jumpHosts = SSHConfigParser.parseProxyJump(proxyJump)
        }
    }

    private func browseForPrivateKey() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        panel.begin { response in
            if response == .OK, let url = panel.url {
                privateKeyPath = url.path(percentEncoded: false)
            }
        }
    }

    private func browseForJumpHostKey(jumpHost: Binding<SSHJumpHost>) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        panel.begin { response in
            if response == .OK, let url = panel.url {
                jumpHost.wrappedValue.privateKeyPath = url.path(percentEncoded: false)
            }
        }
    }
}
