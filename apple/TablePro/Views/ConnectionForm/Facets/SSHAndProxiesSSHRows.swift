//
//  SSHAndProxiesSSHRows.swift
//  TablePro
//

import SwiftUI
import TableProSSHConfig
import TableProSSHTransport

struct SSHAndProxiesSSHRow: View {
    let row: BuiltInRow
    @ObservedObject var store: ConnectionEditorStore

    private var editorRow: EditorRow { .builtIn(row) }

    var body: some View {
        switch row {
        case .sshProfileMissing:
            SSHAndProxiesMissingProfileRow(store: store)
        case .sshConfigHost:
            SSHAndProxiesPicker(String(localized: "Config Host"), selection: store.sshConfigHostBinding, row: editorRow, store: store) {
                Text(String(localized: "Manual")).tag("")
                ForEach(store.context.sshConfigEntries) { entry in
                    Text(verbatim: entry.displayName).tag(entry.host)
                }
            }
        case .sshHost:
            EditorTextRow(
                String(localized: "SSH Host"),
                text: store.binding(\.ssh.host),
                prompt: "ssh.example.com",
                row: editorRow,
                store: store
            )
        case .sshPort:
            EditorTextRow(String(localized: "SSH Port"), text: store.binding(\.ssh.port), prompt: "22", row: editorRow, store: store)
        case .sshUsername:
            EditorTextRow(
                String(localized: "SSH User"),
                text: store.binding(\.ssh.username),
                prompt: String(localized: "username"),
                row: editorRow,
                store: store
            )
        case .sshAuthMethod:
            SSHAndProxiesPicker(String(localized: "Method"), selection: store.binding(\.ssh.authMethod), row: editorRow, store: store) {
                ForEach(SSHAuthMethod.allCases) { method in
                    Text(method.displayName).tag(method)
                }
            }
        case .sshPassword:
            EditorSecureRow(String(localized: "Password"), text: store.binding(\.ssh.password), row: editorRow, store: store)
        case .sshAgentSocket:
            agentSocketRows
        case .sshIdentityFile:
            EditorPathRow(
                String(localized: "Identity File"),
                path: store.binding(\.ssh.privateKeyPath),
                prompt: "~/.ssh/id_ed25519.pub",
                row: editorRow,
                store: store
            ) {
                await TransportFilePanel.chooseSSHKey(message: String(localized: "Choose a public key file"), store: store)
            }
        case .sshKeyFile:
            EditorPathRow(
                String(localized: "Key File"),
                path: store.binding(\.ssh.privateKeyPath),
                prompt: "~/.ssh/id_ed25519",
                row: editorRow,
                store: store
            ) {
                await TransportFilePanel.chooseSSHKey(message: String(localized: "Choose a private key file"), store: store)
            }
        case .sshKeyPassphrase:
            EditorSecureRow(
                String(localized: "Passphrase"),
                text: store.binding(\.ssh.keyPassphrase),
                prompt: String(localized: "Required only for an encrypted key"),
                row: editorRow,
                store: store
            )
        case .sshNoAuthenticationNote:
            Text(String(
                localized: "No credentials are sent. Use this when the server handles authentication itself, such as a Tailscale SSH host."
            ))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(editorRow.accessibilityIdentifier)
        case .sshTOTPMode:
            SSHAndProxiesPicker(String(localized: "TOTP"), selection: store.binding(\.ssh.totpMode), row: editorRow, store: store) {
                ForEach(TOTPMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        case .sshTOTPSecret:
            EditorSecureRow(String(localized: "TOTP Secret"), text: store.binding(\.ssh.totpSecret), row: editorRow, store: store)
                .help(String(localized: "Base32-encoded secret from your authenticator setup"))
        case .sshTOTPAlgorithm:
            SSHAndProxiesPicker(String(localized: "Algorithm"), selection: store.binding(\.ssh.totpAlgorithm), row: editorRow, store: store) {
                ForEach(TOTPAlgorithm.allCases) { algorithm in
                    Text(verbatim: algorithm.rawValue).tag(algorithm)
                }
            }
        case .sshTOTPDigits:
            SSHAndProxiesPicker(String(localized: "Digits"), selection: store.binding(\.ssh.totpDigits), row: editorRow, store: store) {
                Text(verbatim: "6").tag(6)
                Text(verbatim: "8").tag(8)
            }
        case .sshTOTPPeriod:
            SSHAndProxiesPicker(String(localized: "Period"), selection: store.binding(\.ssh.totpPeriod), row: editorRow, store: store) {
                Text(String(localized: "30 seconds")).tag(30)
                Text(String(localized: "60 seconds")).tag(60)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var agentSocketRows: some View {
        let option = store.draft.ssh.agentSocketOption
        SSHAndProxiesPicker(
            String(localized: "Agent Socket"),
            selection: store.binding(\.ssh.agentSocketOption),
            row: editorRow,
            store: store,
            subtitle: option.explanation
        ) {
            ForEach(SSHAgentSocketOption.allCases) { option in
                Text(option.displayName).tag(option)
            }
        }
        if option == .custom {
            TextField(
                String(localized: "Path"),
                text: store.binding(\.ssh.customAgentSocketPath),
                prompt: Text(verbatim: "/path/to/agent.sock")
            )
            .autocorrectionDisabled()
            .accessibilityIdentifier("\(editorRow.accessibilityIdentifier)-path")
        }
    }
}

// A menu picker whose label carries the row's issue, revealed once the person picks something.
struct SSHAndProxiesPicker<Value: Hashable, Content: View>: View {
    private let title: String
    @Binding private var selection: Value
    private let row: EditorRow
    @ObservedObject private var store: ConnectionEditorStore
    private let subtitle: String?
    private let content: Content

    @State private var isEdited = false

    init(
        _ title: String,
        selection: Binding<Value>,
        row: EditorRow,
        store: ConnectionEditorStore,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        _selection = selection
        self.row = row
        self.store = store
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        Picker(selection: $selection) {
            content
        } label: {
            EditorRowLabel(title, row: row, store: store, subtitle: subtitle, isEdited: isEdited)
        }
        .accessibilityIdentifier(row.accessibilityIdentifier)
        .onChange(of: selection) { _ in isEdited = true }
    }
}

struct SSHAndProxiesProfileRows: View {
    @ObservedObject var store: ConnectionEditorStore

    private let row = EditorRow.builtIn(.sshProfile)

    var body: some View {
        SSHAndProxiesPicker(String(localized: "SSH Profile"), selection: store.sshProfileBinding, row: row, store: store) {
            Text(String(localized: "Inline Configuration")).tag(UUID?.none)
            if store.sshProfileIsUnresolved, let missingId = store.draft.ssh.profileId {
                Text(String(localized: "Missing Profile")).tag(UUID?.some(missingId))
            }
            ForEach(store.context.sshProfiles) { profile in
                Text(verbatim: Self.menuTitle(for: profile)).tag(UUID?.some(profile.id))
            }
        }

        if let profile = store.selectedSSHProfile {
            LabeledContent(String(localized: "Server")) {
                Text(verbatim: Self.endpoint(of: profile))
                    .textSelection(.enabled)
            }
            LabeledContent(String(localized: "Authentication")) {
                Text(profile.authMethod.displayName)
            }
            if !profile.privateKeyPath.isEmpty {
                LabeledContent(profile.authMethod == .sshAgent ? String(localized: "Identity File") : String(localized: "Key File")) {
                    Text(verbatim: profile.privateKeyPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(profile.privateKeyPath)
                }
            }
            if !profile.jumpHosts.isEmpty {
                LabeledContent(String(localized: "Jump Hosts")) {
                    Text(profile.jumpHosts.count, format: .number)
                }
            }
        }

        HStack(spacing: 8) {
            Button(String(localized: "Create New Profile…")) {
                store.presentSSHProfileCreation()
            }
            .accessibilityIdentifier("connection-form-ssh-profile-create")
            if store.selectedSSHProfile != nil {
                Button(String(localized: "Edit Profile…")) {
                    store.presentSSHProfileEditing()
                }
                .accessibilityIdentifier("connection-form-ssh-profile-edit")
            }
            if store.canSaveSSHAsProfile {
                Button(String(localized: "Save Current as Profile…")) {
                    store.presentSaveSSHAsProfile()
                }
                .accessibilityIdentifier("connection-form-ssh-profile-save-current")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private static func menuTitle(for profile: SSHProfile) -> String {
        let user = profile.username.trimmingCharacters(in: .whitespaces)
        let target = user.isEmpty ? profile.host : "\(user)@\(profile.host)"
        return "\(profile.name) (\(target))"
    }

    private static func endpoint(of profile: SSHProfile) -> String {
        let user = profile.username.trimmingCharacters(in: .whitespaces)
        let hostAndPort = "\(profile.host):\(profile.port ?? 22)"
        return user.isEmpty ? hostAndPort : "\(user)@\(hostAndPort)"
    }
}

private struct SSHAndProxiesMissingProfileRow: View {
    @ObservedObject var store: ConnectionEditorStore

    private let row = EditorRow.builtIn(.sshProfileMissing)

    // Shown at once, unlike an edit issue: the link points nowhere until it is replaced or the profile returns.
    private var message: String {
        store.context.sshProfilesLoadFailed
            ? String(localized: "TablePro could not read the SSH profiles on this Mac.")
            : String(localized: "The SSH profile this connection uses isn't on this Mac.")
    }

    var body: some View {
        LabeledContent {
            Button(String(localized: "Switch to Inline Configuration")) {
                store.switchSSHProfileToInline()
            }
            .accessibilityIdentifier(row.accessibilityIdentifier)
        } label: {
            NoticeLabel(message, severity: .warning)
        }
    }
}
