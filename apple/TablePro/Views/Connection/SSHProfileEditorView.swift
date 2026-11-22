//
//  SSHProfileEditorView.swift
//  TablePro
//

import SwiftUI
import TableProSSHConfig
import TableProSSHTransport

struct SSHProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let existingProfile: SSHProfile?
    var initialPassword: String?
    var initialKeyPassphrase: String?
    var initialTOTPSecret: String?
    var onSave: ((SSHProfile) -> Void)?
    var onDelete: (() -> Void)?

    @State private var profileName: String = ""

    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var username: String = ""

    @State private var authMethod: SSHAuthMethod = .password
    @State private var password = StoredSecretDraft(stored: .absent)
    @State private var privateKeyPath: String = ""
    @State private var keyPassphrase = StoredSecretDraft(stored: .absent)
    @State private var agentSocketOption: SSHAgentSocketOption = .systemDefault
    @State private var customAgentSocketPath: String = ""

    @State private var totpMode: TOTPMode = .none
    @State private var totpSecret = StoredSecretDraft(stored: .absent)
    @State private var totpAlgorithm: TOTPAlgorithm = .sha1
    @State private var totpDigits: Int = 6
    @State private var totpPeriod: Int = 30

    @State private var jumpHosts: [SSHJumpHost] = []

    @State private var sshConfigEntries: [SSHConfigEntry] = []
    @State private var selectedSSHConfigHost: String = ""

    // Read once on appear: the profiles live in UserDefaults and body runs on every keystroke.
    @State private var isStored = false
    @State private var showingDeleteConfirmation = false
    @State private var saveError: String?
    @State private var connectionsUsingProfile = 0
    @State private var isTesting = false
    @State private var testSucceeded = false
    @State private var testError: String?
    @State private var testTask: Task<Void, Never>?

    private var storage: SSHProfileStorage { .shared }

    private var isValid: Bool {
        let nameValid = !profileName.trimmingCharacters(in: .whitespaces).isEmpty
        let hostValid = !host.trimmingCharacters(in: .whitespaces).isEmpty
        let portValid = port.isEmpty || (Int(port).map { (1...65_535).contains($0) } ?? false)
        let authValid = authMethod == .password || authMethod == .sshAgent
            || authMethod == .keyboardInteractive || authMethod == .none || !privateKeyPath.isEmpty
        let jumpValid = jumpHosts.allSatisfy(\.isValid)
        return nameValid && hostValid && portValid && authValid && jumpValid
    }

    private var resolvedAgentSocketPath: String {
        agentSocketOption.resolvedPath(customPath: customAgentSocketPath)
    }

    private var usesPassword: Bool {
        authMethod == .password || authMethod == .keyboardInteractive
    }

    var body: some View {
        VStack(spacing: 0) {
            ProfileSheetHeader(
                title: isStored ? String(localized: "Edit SSH Profile") : String(localized: "New SSH Profile"),
                subtitle: String(localized: "Connections that use this profile reach their database through this SSH server.")
            )
            Divider()

            Form {
                Section(String(localized: "Profile")) {
                    TextField(String(localized: "Name"), text: $profileName, prompt: Text("My Server"))
                }

                serverSection
                authenticationSection

                if authMethod.supportsTwoFactorAuthentication {
                    totpSection
                }

                jumpHostsSection
            }
            .formStyle(.grouped)

            Divider()
            bottomBar
        }
        .frame(minWidth: 520, minHeight: 440, idealHeight: 560)
        .onAppear {
            loadExistingProfile()
        }
        .task {
            let entries = await Task.detached { SSHConfigParser.parse() }.value
            sshConfigEntries = entries
        }
        .onChange(of: host) { _ in testSucceeded = false }
        .onChange(of: port) { _ in testSucceeded = false }
        .onChange(of: username) { _ in testSucceeded = false }
        .onChange(of: authMethod) { _ in testSucceeded = false }
        .onChange(of: password.text) { _ in testSucceeded = false }
        .onChange(of: privateKeyPath) { _ in testSucceeded = false }
        .onChange(of: keyPassphrase.text) { _ in testSucceeded = false }
        .onChange(of: agentSocketOption) { _ in testSucceeded = false }
        .onChange(of: customAgentSocketPath) { _ in testSucceeded = false }
        .onChange(of: totpMode) { _ in testSucceeded = false }
        .onChange(of: totpSecret.text) { _ in testSucceeded = false }
        .onChange(of: jumpHosts) { _ in testSucceeded = false }
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
                .onChange(of: selectedSSHConfigHost) { _ in
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
                    Text(method.displayName).tag(method)
                }
            }
            if authMethod == .password {
                SecureField(String(localized: "Password"), text: $password.text)
                StoredSecretNotice(draft: $password)
            } else if authMethod == .sshAgent {
                Picker(String(localized: "Agent Socket"), selection: $agentSocketOption) {
                    ForEach(SSHAgentSocketOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                if agentSocketOption == .custom {
                    TextField(
                        String(localized: "Custom Path"),
                        text: $customAgentSocketPath,
                        prompt: Text("/path/to/agent.sock")
                    )
                }
                Text(agentSocketOption.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent(String(localized: "Identity File")) {
                    HStack {
                        TextField("", text: $privateKeyPath, prompt: Text("~/.ssh/id_ed25519.pub"))
                        Button(String(localized: "Browse…")) { browseForPrivateKey() }
                    }
                }
                Text(String(localized: """
                Offers the agent key matching this public key file first. With IdentitiesOnly yes \
                in ~/.ssh/config, only that key is offered.
                """))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if authMethod == .keyboardInteractive {
                SecureField(String(localized: "Password"), text: $password.text)
                StoredSecretNotice(draft: $password)
                Text(String(localized: "Password is sent via keyboard-interactive challenge-response."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if authMethod == .none {
                Text("No credentials are sent. Use this when the server handles authentication itself, such as a Tailscale SSH host.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent(String(localized: "Key File")) {
                    HStack {
                        TextField("", text: $privateKeyPath, prompt: Text("~/.ssh/id_rsa"))
                        Button(String(localized: "Browse…")) { browseForPrivateKey() }
                    }
                }
                SecureField(String(localized: "Passphrase"), text: $keyPassphrase.text)
                StoredSecretNotice(draft: $keyPassphrase)
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
                SecureField(String(localized: "TOTP Secret"), text: $totpSecret.text)
                    .help(String(localized: "Base32-encoded secret from your authenticator setup"))
                StoredSecretNotice(draft: $totpSecret)

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
            } else {
                Text(String(localized: "If the SSH server asks for a verification code, TablePro prompts you for it when you connect."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Jump Hosts Section

    private var jumpHostsSection: some View {
        Section {
            DisclosureGroup(String(localized: "Jump Hosts")) {
                ForEach(jumpHosts) { jumpHost in
                    let jumpHostBinding = $jumpHosts.element(jumpHost)
                    DisclosureGroup {
                        TextField(String(localized: "Host"), text: jumpHostBinding.host, prompt: Text("bastion.example.com"))
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
                            TextField(String(localized: "Username"), text: jumpHostBinding.username, prompt: Text("admin"))
                        }
                        Picker(String(localized: "Auth"), selection: jumpHostBinding.authMethod) {
                            ForEach(SSHJumpAuthMethod.allCases) { method in
                                Text(Self.jumpAuthLabel(method)).tag(method)
                            }
                        }
                        if jumpHost.authMethod == .privateKey {
                            LabeledContent(String(localized: "Key File")) {
                                HStack {
                                    TextField("", text: jumpHostBinding.privateKeyPath, prompt: Text("~/.ssh/id_rsa"))
                                    Button(String(localized: "Browse…")) {
                                        browseForJumpHostKey(jumpHost: jumpHostBinding)
                                    }
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
                                withMotion { jumpHosts.removeAll { $0.id == idToRemove } }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(String(localized: "Remove jump host"))
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

    private static func jumpAuthLabel(_ method: SSHJumpAuthMethod) -> String {
        switch method {
        case .privateKey: String(localized: "Private Key")
        case .sshAgent: String(localized: "SSH Agent")
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            if isStored {
                Button(role: .destructive) {
                    let profileId = existingProfile?.id
                    connectionsUsingProfile = ConnectionStorage.shared.loadConnections()
                        .filter { connection in profileId.map { connection.isLinked(toSSHProfile: $0) } ?? false }
                        .count
                    showingDeleteConfirmation = true
                } label: {
                    Text("Delete Profile")
                }
                .alert(
                    String(localized: "Delete SSH Profile?"),
                    isPresented: $showingDeleteConfirmation
                ) {
                    Button(String(localized: "Delete"), role: .destructive) { deleteProfile() }
                    Button(String(localized: "Cancel"), role: .cancel) {}
                } message: {
                    if connectionsUsingProfile > 0 {
                        Text("Used by ^[\(connectionsUsingProfile) connection](inflect: true). Each keeps this configuration as its own SSH tunnel.")
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
                    } else if testSucceeded {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if testError != nil {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                    }
                    Text("Test Connection")
                }
            }
            .disabled(isTesting || !isValid)

            if let saveError {
                NoticeLabel(saveError, severity: .error)
                    .font(.caption)
                    .lineLimit(3)
                    .truncationMode(.tail)
            } else if testSucceeded {
                NoticeLabel(String(localized: "Connected"), severity: .success)
                    .font(.caption)
            } else if let testError {
                NoticeLabel(testError)
                    .font(.caption)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }

            Spacer()

            Button(String(localized: "Cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button(isStored ? String(localized: "Save") : String(localized: "Create")) { saveProfile() }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
        .padding()
    }

    // MARK: - Actions

    private func loadExistingProfile() {
        guard let profile = existingProfile else { return }
        isStored = storage.profile(for: profile.id) != nil
        profileName = profile.name
        host = profile.host
        port = profile.port.map(String.init) ?? ""
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

        // The fallbacks are what "Save Current as Profile" carries over from the inline tunnel.
        password = StoredSecretDraft(
            stored: storage.storedSecret(.password, for: profile.id),
            fallback: initialPassword
        )
        keyPassphrase = StoredSecretDraft(
            stored: storage.storedSecret(.keyPassphrase, for: profile.id),
            fallback: initialKeyPassphrase
        )
        totpSecret = StoredSecretDraft(
            stored: storage.storedSecret(.totpSecret, for: profile.id),
            fallback: initialTOTPSecret
        )
    }

    private func saveProfile() {
        let profile = SSHProfile(
            id: existingProfile?.id ?? UUID(),
            name: profileName.trimmingCharacters(in: .whitespaces),
            host: host,
            port: Int(port),
            username: username,
            authMethod: authMethod,
            privateKeyPath: privateKeyPath,
            agentSocketPath: resolvedAgentSocketPath,
            jumpHosts: jumpHosts,
            totpMode: totpMode,
            totpAlgorithm: totpAlgorithm,
            totpDigits: totpDigits,
            totpPeriod: totpPeriod
        )

        let outcome = storage.save(profile, isNew: !isStored, secrets: [
            .password: password.change(inUse: usesPassword),
            .keyPassphrase: keyPassphrase.change(inUse: authMethod == .privateKey),
            .totpSecret: totpSecret.change(inUse: totpMode == .autoGenerate),
        ])

        switch outcome {
        case .recordNotSaved:
            saveError = String(localized: "Could not save the profile. Reopen the SSH settings and try again.")
        case .secretsNotSaved(let kinds):
            // The record exists now, so a retry has to update it rather than add a second one.
            isStored = true
            saveError = StoredSecretCopy.notStoredMessage(kinds.map(Self.secretName))
        case .saved:
            saveError = nil
            onSave?(profile)
            dismiss()
        }
    }

    private static func secretName(_ kind: SSHProfileStorage.SecretKind) -> String {
        switch kind {
        case .password: String(localized: "the password")
        case .keyPassphrase: String(localized: "the key passphrase")
        case .totpSecret: String(localized: "the TOTP secret")
        }
    }

    func testSSHConnection() {
        isTesting = true
        testSucceeded = false
        testError = nil

        let config = SSHConfiguration(
            enabled: true,
            host: host,
            port: Int(port),
            username: username,
            authMethod: authMethod,
            privateKeyPath: privateKeyPath,
            agentSocketPath: resolvedAgentSocketPath,
            jumpHosts: jumpHosts,
            totpMode: totpMode,
            totpAlgorithm: totpAlgorithm,
            totpDigits: totpDigits,
            totpPeriod: totpPeriod
        )

        let credentials = SSHTunnelCredentials(
            sshPassword: password.text.isEmpty ? nil : password.text,
            keyPassphrase: keyPassphrase.text.isEmpty ? nil : keyPassphrase.text,
            totpSecret: totpSecret.text.isEmpty ? nil : totpSecret.text,
            keyboardInteractivePromptProvider: nil
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
                    testError = error.localizedDescription
                }
            }
        }
    }

    private func deleteProfile() {
        guard let profile = existingProfile else { return }
        guard storage.deleteProfile(profile) else {
            saveError = String(localized: "Could not delete the profile. Reopen the SSH settings and try again.")
            return
        }
        onDelete?()
        dismiss()
    }

    // MARK: - SSH Config Helpers

    private func applySSHConfigEntry(_ configHost: String) {
        guard !configHost.isEmpty else { return }
        host = configHost
    }

    private func browseForPrivateKey() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                privateKeyPath = url.path(percentEncoded: false)
            }
        }
    }

    private func browseForJumpHostKey(jumpHost: Binding<SSHJumpHost>) {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                jumpHost.wrappedValue.privateKeyPath = url.path(percentEncoded: false)
            }
        }
    }
}

// MARK: - Shared by the profile sheets

struct ProfileSheetHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }
}

// Shown under a secret field whose saved value the Keychain would not return.
struct StoredSecretNotice: View {
    @Binding var draft: StoredSecretDraft

    var body: some View {
        if draft.showsUnreadableNotice {
            LabeledContent {
                if draft.removesUnreadable {
                    Button(String(localized: "Keep")) { draft.removesUnreadable = false }
                } else {
                    Button(String(localized: "Remove")) { draft.removesUnreadable = true }
                }
            } label: {
                NoticeLabel(
                    draft.removesUnreadable
                        ? String(localized: "The saved value is removed when you save.")
                        : String(localized: "The Keychain could not read the saved value, so it is not shown. Saving keeps it unless you type a new one.")
                )
                .font(.caption)
            }
        }
    }
}

enum StoredSecretCopy {
    static func notStoredMessage(_ names: [String]) -> String {
        let list = ListFormatter.localizedString(byJoining: names)
        let template = names.count == 1
            ? String(localized: "The profile was saved, but the Keychain could not store %@. Enter it again and click Save.")
            : String(localized: "The profile was saved, but the Keychain could not store %@. Enter them again and click Save.")
        return String(format: template, list)
    }
}
