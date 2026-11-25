import AppKit
import SwiftUI
import TableProSSHConfig
import TableProSSHTransport

// The SSH profile editor's Server, Authentication, Two-Factor and Jump Hosts sections.
struct SSHServerFields: View {
    @Binding var draft: SSHServerDraft
    let configEntries: [SSHConfigEntry]
    let identifierPrefix: String
    // Revealing a secret the Keychain handed over asks for authentication first.
    var savedSecrets: Set<SSHSecret> = []

    var body: some View {
        serverSection
        authenticationSection
        if draft.authMethod.supportsTwoFactorAuthentication {
            twoFactorSection
        }
        jumpHostsSection
        ForEach(draft.jumpHosts) { hop in
            jumpHostSection(hop)
        }
    }

    private var serverSection: some View {
        Section(String(localized: "Server")) {
            if !configEntries.isEmpty {
                Picker(String(localized: "Config Host"), selection: configHost) {
                    Text("Manual").tag("")
                    ForEach(configEntries) { entry in
                        Text(verbatim: entry.displayName).tag(entry.host)
                    }
                }
                .accessibilityIdentifier("\(identifierPrefix)-config-host")
            }
            if draft.selectedConfigHost.isEmpty || configEntries.isEmpty {
                TextField(String(localized: "Host"), text: $draft.host, prompt: Text(verbatim: "ssh.example.com"))
                    .accessibilityIdentifier("\(identifierPrefix)-host")
            }
            TextField(text: $draft.port, prompt: Text(verbatim: "22")) {
                Text("Port")
                if !draft.portIsValid {
                    NoticeLabel(String(localized: "SSH port must be between 1 and 65535"), severity: .error)
                }
            }
            .accessibilityIdentifier("\(identifierPrefix)-port")
            TextField(String(localized: "Username"), text: $draft.username, prompt: Text("username"))
                .accessibilityIdentifier("\(identifierPrefix)-username")
        }
    }

    private var configHost: Binding<String> {
        Binding(
            get: { draft.selectedConfigHost },
            set: { draft.selectConfigHost($0) }
        )
    }

    private var authenticationSection: some View {
        Section(String(localized: "Authentication")) {
            Picker(selection: $draft.authMethod) {
                ForEach(SSHAuthMethod.allCases) { method in
                    Text(method.displayName).tag(method)
                }
            } label: {
                Text("Method")
                if let help = methodHelp {
                    Text(help)
                }
            }
            .accessibilityIdentifier("\(identifierPrefix)-auth-method")

            switch draft.authMethod {
            case .password, .keyboardInteractive:
                RevealablePasswordField(
                    title: String(localized: "Password"),
                    text: $draft.password,
                    requiresAuthentication: savedSecrets.contains(.password)
                )
            case .sshAgent:
                Picker(selection: $draft.agentSocketOption) {
                    ForEach(SSHAgentSocketOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                } label: {
                    Text("Agent Socket")
                    Text(draft.agentSocketOption.explanation)
                }
                if draft.agentSocketOption == .custom {
                    TextField(
                        String(localized: "Custom Path"),
                        text: $draft.customAgentSocketPath,
                        prompt: Text(verbatim: "/path/to/agent.sock")
                    )
                }
                keyFileRow(
                    title: String(localized: "Identity File"),
                    subtitle: String(localized: """
                    Offers the agent key matching this public key file first. With IdentitiesOnly yes \
                    in ~/.ssh/config, only that key is offered.
                    """),
                    path: $draft.privateKeyPath,
                    prompt: "~/.ssh/id_ed25519.pub",
                    panelMessage: String(localized: "Choose a public key file"),
                    identifier: "\(identifierPrefix)-identity-file"
                )
            case .privateKey:
                keyFileRow(
                    title: String(localized: "Key File"),
                    subtitle: draft.privateKeyPath.isEmpty
                        ? String(localized: "Auto-detects from ~/.ssh/config and default key locations.")
                        : nil,
                    path: $draft.privateKeyPath,
                    prompt: "~/.ssh/id_rsa",
                    panelMessage: String(localized: "Choose a private key file"),
                    identifier: "\(identifierPrefix)-key-file"
                )
                RevealablePasswordField(
                    title: String(localized: "Passphrase"),
                    text: $draft.keyPassphrase,
                    requiresAuthentication: savedSecrets.contains(.keyPassphrase),
                    revealTitle: String(localized: "Show passphrase")
                )
            case .none:
                EmptyView()
            }
        }
    }

    private var methodHelp: String? {
        switch draft.authMethod {
        case .keyboardInteractive:
            String(localized: "Password is sent via keyboard-interactive challenge-response.")
        case .none:
            String(localized: "No credentials are sent. Use this when the server handles authentication itself, such as a Tailscale SSH host.")
        case .password, .privateKey, .sshAgent:
            nil
        }
    }

    private var twoFactorSection: some View {
        Section(String(localized: "Two-Factor Authentication")) {
            Picker(String(localized: "TOTP"), selection: $draft.totpMode) {
                ForEach(TOTPMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .accessibilityIdentifier("\(identifierPrefix)-totp-mode")

            if draft.totpMode == .autoGenerate {
                RevealablePasswordField(
                    title: String(localized: "TOTP Secret"),
                    subtitle: String(localized: "Base32-encoded secret from your authenticator setup"),
                    text: $draft.totpSecret,
                    requiresAuthentication: savedSecrets.contains(.totpSecret),
                    revealTitle: String(localized: "Show secret")
                )
                Picker(String(localized: "Algorithm"), selection: $draft.totpAlgorithm) {
                    ForEach(TOTPAlgorithm.allCases) { algorithm in
                        Text(verbatim: algorithm.rawValue).tag(algorithm)
                    }
                }
                Picker(String(localized: "Digits"), selection: $draft.totpDigits) {
                    SettingsChoiceItems([6, 8], including: draft.totpDigits) { digits in
                        Text(verbatim: SettingsFormat.identifier(digits))
                    }
                }
                Picker(String(localized: "Period"), selection: $draft.totpPeriod) {
                    SettingsChoiceItems([30, 60], including: draft.totpPeriod) { seconds in
                        Text(verbatim: SettingsFormat.duration(seconds: seconds))
                    }
                }
            } else {
                SettingsHelpRow(
                    "If the SSH server asks for a verification code, TablePro prompts you for it when you connect."
                )
            }
        }
    }

    private var jumpHostsSection: some View {
        Section {
            SettingsHelpRow(
                "Jump hosts are connected in order before reaching the SSH server above. Only key and agent auth are supported for jumps."
            )
        } header: {
            Text("Jump Hosts")
        } footer: {
            SettingsSectionActions {
                Button(String(localized: "Add Jump Host")) {
                    withMotion { draft.addJumpHost() }
                }
                .accessibilityIdentifier("\(identifierPrefix)-add-jump-host")
            }
        }
    }

    private func jumpHostSection(_ hop: SSHJumpHost) -> some View {
        let position = draft.jumpHosts.firstIndex { $0.id == hop.id } ?? 0
        let binding = $draft.jumpHosts.element(hop)
        let identifier = "\(identifierPrefix)-jump-host-\(position + 1)"
        return Section(String(format: String(localized: "Jump Host %lld"), Int64(position + 1))) {
            TextField(String(localized: "Host"), text: binding.host, prompt: Text(verbatim: "bastion.example.com"))
                .accessibilityIdentifier("\(identifier)-host")
            TextField(String(localized: "Port"), text: Self.portText(binding.port), prompt: Text(verbatim: "22"))
                .accessibilityIdentifier("\(identifier)-port")
            TextField(String(localized: "Username"), text: binding.username, prompt: Text(verbatim: "admin"))
                .accessibilityIdentifier("\(identifier)-username")
            Picker(String(localized: "Authentication"), selection: binding.authMethod) {
                ForEach(SSHJumpAuthMethod.allCases) { method in
                    Text(method.displayName).tag(method)
                }
            }
            if hop.authMethod == .privateKey {
                keyFileRow(
                    title: String(localized: "Key File"),
                    subtitle: nil,
                    path: binding.privateKeyPath,
                    prompt: "~/.ssh/id_rsa",
                    panelMessage: String(localized: "Choose a private key file"),
                    identifier: "\(identifier)-key-file"
                )
            }
            HStack(spacing: 8) {
                Button {
                    withMotion { draft.moveJumpHost(id: hop.id, by: -1) }
                } label: {
                    Label(String(localized: "Move Up"), systemImage: "chevron.up")
                        .labelStyle(.iconOnly)
                }
                .help(String(localized: "Move Up"))
                .disabled(position == 0)
                Button {
                    withMotion { draft.moveJumpHost(id: hop.id, by: 1) }
                } label: {
                    Label(String(localized: "Move Down"), systemImage: "chevron.down")
                        .labelStyle(.iconOnly)
                }
                .help(String(localized: "Move Down"))
                .disabled(position == draft.jumpHosts.count - 1)
                Spacer()
                Button(String(localized: "Remove Jump Host"), role: .destructive) {
                    withMotion { draft.removeJumpHost(id: hop.id) }
                }
                .accessibilityIdentifier("\(identifier)-remove")
            }
            .buttonStyle(.bordered)
        }
    }

    private static func portText(_ port: Binding<Int?>) -> Binding<String> {
        Binding(
            get: { port.wrappedValue.map(String.init) ?? "" },
            set: { port.wrappedValue = Int($0.trimmingCharacters(in: .whitespaces)) }
        )
    }

    private func keyFileRow(
        title: String,
        subtitle: String?,
        path: Binding<String>,
        prompt: String,
        panelMessage: String,
        identifier: String
    ) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                TextField(title, text: path, prompt: Text(verbatim: prompt))
                    .labelsHidden()
                    .accessibilityIdentifier(identifier)
                Button(String(localized: "Choose…")) {
                    Self.chooseKeyFile(message: panelMessage) { path.wrappedValue = $0 }
                }
                .accessibilityIdentifier("\(identifier)-choose")
            }
        } label: {
            Text(verbatim: title)
            if let subtitle {
                Text(verbatim: subtitle)
            }
        }
    }

    // A sheet on the window that asked, so the panel cannot slip behind it.
    private static func chooseKeyFile(message: String, onSelect: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.message = message
        guard let window = NSApp.keyWindow else {
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                onSelect(url.path(percentEncoded: false))
            }
            return
        }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            onSelect(url.path(percentEncoded: false))
        }
    }
}
