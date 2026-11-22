//
//  SSHAndProxiesFacetView.swift
//  TablePro
//

import SwiftUI
import TableProSSHConfig
import TableProSSHTransport

struct SSHAndProxiesFacetView: View {
    @ObservedObject var store: ConnectionEditorStore

    var body: some View {
        Form {
            if let facet = store.layout.facet(.sshAndProxies) {
                ForEach(facet.sections) { section in
                    SSHAndProxiesSectionView(section: section, store: store)
                }
            }
        }
        .formStyle(.grouped)
        .scrollsToEditorFocus(.sshAndProxies, store: store)
    }
}

private struct SSHAndProxiesSectionView: View {
    let section: SectionLayout
    @ObservedObject var store: ConnectionEditorStore

    // A code editor is a Section of its own, so a JSON key never sits between two toggles.
    private static let standaloneRows: Set<EditorRow> = [.builtIn(.cloudSQLServiceAccountKey)]

    private var standaloneRow: EditorRow? {
        guard section.rows.count > 1 else { return nil }
        return section.rows.first { Self.standaloneRows.contains($0) }
    }

    private var inlineRows: [EditorRow] {
        guard let standaloneRow else { return section.rows }
        return section.rows.filter { $0 != standaloneRow }
    }

    private var isHidden: Bool {
        section.id == "tunnelPreview" && store.tunnelCommandPreview == nil
    }

    var body: some View {
        if section.id == "sshJumpHosts" {
            SSHAndProxiesJumpHostSections(rows: section.rows, store: store)
        } else if !isHidden {
            Section {
                ForEach(inlineRows, id: \.self) { row in
                    SSHAndProxiesRowView(row: row, store: store)
                        .id(row)
                }
            } header: {
                if let headerTitle {
                    Text(headerTitle)
                }
            } footer: {
                if let footer {
                    Text(footer)
                }
            }
            if let standaloneRow {
                Section {
                    SSHAndProxiesRowView(row: standaloneRow, store: store)
                        .id(standaloneRow)
                } header: {
                    Text(String(localized: "Service Account Key"))
                } footer: {
                    Text(String(localized: "Stored in the macOS Keychain and written to a temporary file only while the proxy runs."))
                }
            }
        }
    }

    // The profile and tunnel method pickers already name their section.
    private var headerTitle: String? {
        switch section.id {
        case "sshProfile", "tunnelMethod": return nil
        default: return section.title
        }
    }

    private var footer: String? {
        let draft = store.draft
        if section.id == "transport", store.transportIsLocationChoice, draft.transport == nil {
            return String(localized: """
                Opens the database file set in General, on this Mac. \
                For a file on another computer, choose Remote Server over SSH.
                """)
        }
        if let footer = section.footer { return footer }
        switch section.id {
        case "remoteFile":
            var lines = [String(localized: "Absolute, or relative to the SSH account's home directory.")]
            if store.traits.supportsRemoteDatabaseSession, draft.ssh.remoteFileAccess == .onServer {
                lines.append(String(localized: "The SSH server needs python3."))
            }
            return lines.joined(separator: "\n")
        case "sshAuthentication":
            return sshAuthenticationFooter(draft.ssh)
        case "sshTwoFactor":
            guard draft.ssh.totpMode != .autoGenerate else { return nil }
            return String(localized: "If the SSH server asks for a verification code, TablePro prompts you for it when you connect.")
        case "forwardTo":
            return forwardToFooter
        case "cloudflareAuthentication":
            switch draft.cloudflare.authMethod {
            case .browserSSO:
                return String(localized: "Signs in to Cloudflare Access once and caches the token, so connecting doesn't open a browser.")
            case .serviceToken:
                return String(
                    localized: "The Access application policy must use a Service Auth rule, or Cloudflare still prompts for browser sign-in."
                )
            }
        case "cloudflareListener":
            return draft.cloudflare.exposeToLAN
                ? String(localized: "Listens on all interfaces (0.0.0.0), reachable from your local network.")
                : String(localized: "Listens only on 127.0.0.1.")
        case "cloudSQLInstance":
            return String(localized: "Find this on the instance's overview page in the Google Cloud console.")
        case "cloudSQLAuthentication":
            return cloudSQLAuthenticationFooter(draft.cloudSQLProxy)
        case "cloudSQLListener":
            return String(localized: "Listens only on 127.0.0.1.")
        case "socksCredentials":
            return String(localized: "Leave blank to connect without authentication. The password is stored in the macOS Keychain.")
        case "tunnelMethod":
            return tunnelMethodFooter(draft.tunnelCommand.config.method)
        case "tunnelKubernetes":
            return String(localized: "The port comes from this connection's own port, forwarded from the resource you name here.")
        case "tunnelAWS":
            return String(
                localized: "The session forwards to this connection's host and port from the target instance, so the target is the bastion rather than the database."
            )
        case "tunnelCustom":
            return String(
                format: String(localized: """
                    %1$@ is the local port, %2$@ and %3$@ are this connection's host and port. \
                    The command runs directly rather than through a shell, so start it with \
                    /usr/bin/env if you need environment variables.
                    """),
                TunnelCommandLine.localPortPlaceholder,
                TunnelCommandLine.hostPlaceholder,
                TunnelCommandLine.remotePortPlaceholder
            )
        default:
            return nil
        }
    }

    private func sshAuthenticationFooter(_ ssh: SSHDraft) -> String? {
        switch ssh.authMethod {
        case .sshAgent:
            return String(localized: """
                Offers the agent key matching this public key file first. With IdentitiesOnly yes \
                in ~/.ssh/config, only that key is offered.
                """)
        case .privateKey:
            guard ssh.privateKeyPath.isEmpty else { return nil }
            return String(localized: "Auto-detects from ~/.ssh/config and default key locations.")
        case .keyboardInteractive:
            return String(localized: "Password is sent via keyboard-interactive challenge-response.")
        case .password, .none:
            return nil
        }
    }

    private var forwardToFooter: String {
        switch store.sshForwardSocketPathAdvice {
        case .notAbsolute:
            return String(localized: "Enter an absolute path, as it appears on the SSH server.")
        case .looksLikeDirectory:
            return String(localized: "Point at the socket file itself, not the directory holding it.")
        case .none:
            guard store.hostAndPortAreUnused else {
                return String(localized: "Optional. Set this to reach a database that only listens on a Unix socket.")
            }
            return String(localized: """
                The SSH server connects to this socket instead of Host and Port. \
                A database on a socket cannot negotiate TLS, so TablePro turns it off; \
                the SSH tunnel still encrypts the whole path.
                """)
        }
    }

    private func cloudSQLAuthenticationFooter(_ proxy: CloudSQLProxyDraft) -> String? {
        var sentences: [String] = []
        if proxy.authMode == .applicationDefault {
            sentences.append(String(
                localized: "Signs in with this Mac's Application Default Credentials, from “gcloud auth application-default login” or GOOGLE_APPLICATION_CREDENTIALS."
            ))
        }
        if proxy.useIAMAuth {
            sentences.append(String(
                localized: "With IAM, the username in General is the IAM principal, such as a user email or name@project.iam, and no password is sent."
            ))
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    private func tunnelMethodFooter(_ method: TunnelCommandMethod) -> String {
        switch method {
        case .kubectl:
            return String(localized: "Forwards a port from a Kubernetes resource with kubectl port-forward.")
        case .awsSSM:
            return String(localized: "Opens an AWS Systems Manager port forwarding session through a target instance.")
        case .custom:
            return String(localized: "Runs a command you write. It must open the local port itself.")
        }
    }
}

private struct SSHAndProxiesRowView: View {
    let row: EditorRow
    @ObservedObject var store: ConnectionEditorStore

    var body: some View {
        if case .builtIn(let builtIn) = row {
            switch builtIn {
            case .transport:
                SSHAndProxiesTransportPicker(store: store)
            case .sshForwardSocketPath:
                EditorTextRow(
                    String(localized: "Socket Path"),
                    text: store.binding(\.sshForwardUnixSocketPath),
                    prompt: store.traits.defaultUnixSocketPath ?? "/path/to/database.sock",
                    row: row,
                    store: store
                )
            case .remoteFilePath, .remoteFileAccess:
                SSHAndProxiesRemoteFileRow(row: builtIn, store: store)
            case .sshProfile:
                SSHAndProxiesProfileRows(store: store)
            case .sshProfileMissing, .sshConfigHost, .sshHost, .sshPort, .sshUsername, .sshAuthMethod, .sshPassword,
                 .sshAgentSocket, .sshIdentityFile, .sshKeyFile, .sshKeyPassphrase, .sshNoAuthenticationNote,
                 .sshTOTPMode, .sshTOTPSecret, .sshTOTPAlgorithm, .sshTOTPDigits, .sshTOTPPeriod:
                SSHAndProxiesSSHRow(row: builtIn, store: store)
            case .cloudflareHostname, .cloudflareAuthMethod, .cloudflareSignIn, .cloudflareTokenId, .cloudflareTokenSecret,
                 .cloudflareAutomaticPort, .cloudflareLocalPort, .cloudflareExposeToLAN, .cloudflareBinary:
                TransportCloudflareRow(row: builtIn, store: store)
            case .cloudSQLInstance, .cloudSQLAuthMode, .cloudSQLServiceAccountKey, .cloudSQLIAMAuth, .cloudSQLPrivateIP,
                 .cloudSQLAutomaticPort, .cloudSQLLocalPort, .cloudSQLBinary:
                TransportCloudSQLRow(row: builtIn, store: store)
            case .socksHost, .socksPort, .socksUsername, .socksPassword:
                TransportSOCKSRow(row: builtIn, store: store)
            case .tunnelCommandMethod, .kubernetesResource, .kubernetesNamespace, .kubernetesContext, .awsTarget,
                 .awsProfile, .awsRegion, .tunnelCommand, .tunnelCommandExecutable, .tunnelCommandPreview:
                TransportCommandRow(row: builtIn, store: store)
            default:
                EmptyView()
            }
        }
    }
}

private struct SSHAndProxiesTransportPicker: View {
    @ObservedObject var store: ConnectionEditorStore

    private let row = EditorRow.builtIn(.transport)

    var body: some View {
        let isLocation = store.transportIsLocationChoice
        Picker(selection: store.tracking(store.transportBinding, row: row)) {
            ForEach(store.availableTransports, id: \.self) { transport in
                Text(Self.title(of: transport, asLocation: isLocation)).tag(transport)
            }
        } label: {
            EditorRowLabel(
                isLocation ? String(localized: "Location") : String(localized: "Connect Via"),
                row: row,
                store: store,
                subtitle: store.tunnelHostListAdvice
            )
        }
        .accessibilityIdentifier(row.accessibilityIdentifier)
        .editorRowFocus(row, store: store)
    }

    private static func title(of transport: ConnectionTunnelKind?, asLocation: Bool) -> String {
        guard asLocation else { return transport?.displayName ?? ConnectionTunnelKind.directDisplayName }
        switch transport {
        case nil: return String(localized: "This Mac")
        case .remoteFile?: return String(localized: "Remote Server over SSH")
        case let other?: return other.displayName
        }
    }
}

private struct SSHAndProxiesRemoteFileRow: View {
    let row: BuiltInRow
    @ObservedObject var store: ConnectionEditorStore

    var body: some View {
        switch row {
        case .remoteFilePath:
            EditorTextRow(
                String(localized: "Path"),
                text: store.binding(\.ssh.remoteFilePath),
                prompt: "~/database.\(store.traits.fileExtensions.first ?? "db")",
                row: .builtIn(row),
                store: store
            )
        case .remoteFileAccess:
            Picker(selection: store.tracking(store.binding(\.ssh.remoteFileAccess), row: .builtIn(row))) {
                Text(String(localized: "On the Server")).tag(RemoteFileAccess.onServer)
                Text(String(localized: "As a Read-Only Copy")).tag(RemoteFileAccess.readOnlyCopy)
            } label: {
                EditorRowLabel(String(localized: "Open"), row: .builtIn(row), store: store)
            }
            .accessibilityIdentifier(EditorRow.builtIn(row).accessibilityIdentifier)
            .editorRowFocus(.builtIn(row), store: store)
        default:
            EmptyView()
        }
    }
}
