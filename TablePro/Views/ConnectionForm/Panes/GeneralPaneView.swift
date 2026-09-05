//
//  GeneralPaneView.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit
import UniformTypeIdentifiers

/// What a connection is: its name, its type, where it lives, and who it signs in as.
///
/// Everything about how the bytes get there belongs to `NetworkPaneView`, so a connection that
/// needs no tunnel and no TLS never sees a control about either.
struct GeneralPaneView: View {
    @Bindable var coordinator: ConnectionFormCoordinator
    @FocusState private var nameFocused: Bool

    private var type: DatabaseType { coordinator.network.type }
    private var connectionMode: ConnectionMode {
        PluginManager.shared.connectionMode(for: type)
    }

    private var showsBuiltInDatabaseField: Bool {
        coordinator.network.showsBuiltInDatabaseField
    }

    var body: some View {
        Form {
            if let parsed = coordinator.clipboardCandidate {
                Section {
                    ClipboardConnectionBanner(
                        parsed: parsed,
                        onUse: { coordinator.applyClipboardCandidate(parsed) },
                        onDismiss: { coordinator.dismissClipboardCandidate() }
                    )
                    .listRowInsets(EdgeInsets())
                }
            }

            identitySection
            connectionSection
            authenticationSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .defaultFocus($nameFocused, true)
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section {
            TextField(
                String(localized: "Name"),
                text: $coordinator.network.name,
                prompt: Text(String(localized: "Connection name"))
            )
            .focused($nameFocused)
            .accessibilityIdentifier("connection-form-name")

            LabeledContent(String(localized: "Type")) {
                HStack(spacing: 8) {
                    type.iconImage
                        .renderingMode(.template)
                        .foregroundStyle(type.themeColor)
                        .frame(width: 16, height: 16)
                    Text(type.rawValue)
                    Spacer(minLength: 8)
                    Button(String(localized: "Change…")) {
                        coordinator.isChoosingType = true
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("connection-form-change-type")
                }
            }
        }
    }

    // MARK: - Connection

    @ViewBuilder
    private var connectionSection: some View {
        switch connectionMode {
        case .fileBased:
            Section(String(localized: "Database File")) {
                HStack {
                    TextField(
                        String(localized: "File Path"),
                        text: $coordinator.network.database,
                        prompt: Text(filePathPrompt)
                    )
                    .accessibilityIdentifier("connection-form-file-path")
                    Button(String(localized: "Browse…")) {
                        browseForFile()
                    }
                    .controlSize(.small)
                }
            }
        case .apiOnly:
            if showsBuiltInDatabaseField {
                Section(String(localized: "Connection")) {
                    TextField(
                        containerEntityName,
                        text: $coordinator.network.database,
                        prompt: Text(containerEntityPlaceholder)
                    )
                }
            }
        case .network:
            Section {
                hostFieldsView
                if showsBuiltInDatabaseField {
                    TextField(
                        containerEntityName,
                        text: $coordinator.network.database,
                        prompt: Text(containerEntityPlaceholder)
                    )
                }
            } header: {
                Text(String(localized: "Connection"))
            } footer: {
                if usesForwardSocket {
                    Text(String(localized: """
                    Host and Port are unused. The SSH tunnel forwards to the socket path set \
                    on the Network tab.
                    """))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var containerEntityName: String {
        PluginManager.shared.containerEntityName(for: type)
    }

    private var containerEntityPlaceholder: String {
        String(format: String(localized: "%@_name"), containerEntityName.lowercased())
    }

    @ViewBuilder
    private var hostFieldsView: some View {
        let connectionFields = coordinator.network.connectionFields
        if coordinator.network.hasHostListField {
            ForEach(connectionFields, id: \.id) { field in
                if case .hostList = field.fieldType, coordinator.network.isFieldVisible(field) {
                    HostListFieldRow(
                        label: field.label,
                        placeholder: field.placeholder,
                        defaultPort: type.defaultPort,
                        value: networkFieldBinding(for: field)
                    )
                    .accessibilityIdentifier("connection-field-\(field.id)")
                }
            }
        } else {
            TextField(
                String(localized: "Host"),
                text: $coordinator.network.host,
                prompt: Text("localhost")
            )
            .accessibilityIdentifier("connection-form-host")
            .disabled(usesForwardSocket)
            TextField(
                String(localized: "Port"),
                text: $coordinator.network.port,
                prompt: Text(defaultPortString)
            )
            .accessibilityIdentifier("connection-form-port")
            .disabled(usesForwardSocket)
        }
        ForEach(connectionFields, id: \.id) { field in
            if !isHostListField(field) && coordinator.network.isFieldVisible(field) {
                ConnectionFieldRow(
                    field: field,
                    value: networkFieldBinding(for: field)
                )
            }
        }
    }

    private var usesForwardSocket: Bool {
        coordinator.ssh.state.enabled && coordinator.network.forwardsToUnixSocket
    }

    // MARK: - Authentication

    @ViewBuilder
    private var authenticationSection: some View {
        if connectionMode != .fileBased {
            let authFields = coordinator.auth.authFields.splitCredentialControllers()
            Section(String(localized: "Authentication")) {
                ForEach(authFields.usernameControllers, id: \.id) { field in
                    authFieldRow(field)
                }
                if connectionMode == .network && !coordinator.auth.hidesUsername {
                    TextField(
                        String(localized: "Username"),
                        text: $coordinator.auth.username
                    )
                    .accessibilityIdentifier("connection-form-username")
                }
                ForEach(authFields.passwordControllers, id: \.id) { field in
                    authFieldRow(field)
                }
                if !coordinator.auth.hidesPassword {
                    PasswordPromptToggle(
                        type: type,
                        promptForPassword: $coordinator.auth.promptForPassword,
                        password: $coordinator.auth.password,
                        additionalFieldValues: $coordinator.auth.additionalFieldValues
                    )
                }
                ForEach(authFields.rest, id: \.id) { field in
                    authFieldRow(field)
                }
                kerberosCaption
                if coordinator.auth.usePgpass {
                    pgpassStatusView
                }
            }
        }
    }

    @ViewBuilder
    private func authFieldRow(_ field: ConnectionField) -> some View {
        if coordinator.auth.isFieldVisible(field) {
            if FilePathConnectionFieldRow.isFilePathField(field) {
                FilePathConnectionFieldRow(
                    field: field,
                    value: authFieldBinding(for: field),
                    onBrowse: { browseForAuthFile(field: field) }
                )
            } else {
                ConnectionFieldRow(
                    field: field,
                    value: authFieldBinding(for: field)
                )
            }
        }
    }

    @ViewBuilder
    private var pgpassStatusView: some View {
        switch coordinator.auth.pgpassStatus {
        case .notChecked:
            EmptyView()
        case .fileNotFound:
            Label(
                String(localized: "~/.pgpass not found"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.yellow)
            .font(.caption)
        case .badPermissions:
            Label(
                String(localized: "~/.pgpass has incorrect permissions (needs chmod 0600)"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
            .font(.caption)
        case .matchFound:
            Label(
                String(localized: "~/.pgpass found, matching entry exists"),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            .font(.caption)
        case .noMatch:
            Label(
                String(localized: "~/.pgpass found, no matching entry"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.yellow)
            .font(.caption)
        }
    }

    @ViewBuilder
    private var kerberosCaption: some View {
        if type.pluginTypeId == "SQL Server",
           coordinator.auth.additionalFieldValues["mssqlAuthMethod"] == "windows" {
            Label(
                String(localized: "Leave the principal and password blank to use your existing Kerberos ticket. Run kinit user@REALM.COM in Terminal first if you don't have one."),
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if hostIsIPAddress {
                Label(
                    String(localized: "Windows Authentication needs the server's hostname, not an IP address. Kerberos service principals aren't registered against IP addresses."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.yellow)
            }
        }
    }

    private var hostIsIPAddress: Bool {
        coordinator.network.resolvedHostIsIPAddress
    }

    // MARK: - Helpers

    private func isHostListField(_ field: ConnectionField) -> Bool {
        if case .hostList = field.fieldType { return true }
        return false
    }

    private func networkFieldBinding(for field: ConnectionField) -> Binding<String> {
        Binding(
            get: {
                coordinator.network.additionalFieldValues[field.id]
                    ?? field.defaultValue ?? ""
            },
            set: { coordinator.network.additionalFieldValues[field.id] = $0 }
        )
    }

    private func authFieldBinding(for field: ConnectionField) -> Binding<String> {
        Binding(
            get: {
                coordinator.auth.additionalFieldValues[field.id]
                    ?? field.defaultValue ?? ""
            },
            set: { coordinator.auth.additionalFieldValues[field.id] = $0 }
        )
    }

    private var defaultPortString: String {
        let port = type.defaultPort
        return port == 0 ? "" : String(port)
    }

    private var filePathPrompt: String {
        let extensions = PluginManager.shared.fileExtensions(for: type)
        let ext = (extensions.first ?? "db")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !ext.isEmpty else { return "/path/to/database.db" }
        return "/path/to/database.\(ext)"
    }

    private func browseForFile() {
        let types = DatabaseFileTypes.contentTypes(
            forExtensions: PluginManager.shared.fileExtensions(for: type)
        )
        presentFilePanel(contentTypes: types) { path in
            coordinator.network.database = path
        }
    }

    /// Certificates, keys and identity files are not the driver's own file kinds, so this
    /// panel stays open to any file.
    private func browseForAuthFile(field: ConnectionField) {
        presentFilePanel(contentTypes: [.data]) { path in
            coordinator.auth.additionalFieldValues[field.id] = path
        }
    }

    private func presentFilePanel(contentTypes: [UTType], onSelect: @escaping (String) -> Void) {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                onSelect(url.path(percentEncoded: false))
            }
        }
    }
}
