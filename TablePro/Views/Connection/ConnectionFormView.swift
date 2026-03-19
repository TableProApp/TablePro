//
//  ConnectionFormView.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import os
import SwiftUI
import TableProPluginKit
import UniformTypeIdentifiers

// swiftlint:disable file_length

/// Form for creating or editing a database connection
struct ConnectionFormView: View { // swiftlint:disable:this type_body_length
    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionFormView")
    @Environment(\.openWindow) private var openWindow

    // Connection ID: nil = new connection, UUID = edit existing
    let connectionId: UUID?

    private let storage = ConnectionStorage.shared
    private let dbManager = DatabaseManager.shared

    // Computed property for isNew
    private var isNew: Bool { connectionId == nil }

    private var availableDatabaseTypes: [DatabaseType] {
        PluginManager.shared.availableDatabaseTypes
    }

    private var additionalConnectionFields: [ConnectionField] {
        PluginManager.shared.additionalConnectionFields(for: type)
    }

    private var authSectionFields: [ConnectionField] {
        PluginManager.shared.additionalConnectionFields(for: type)
            .filter { $0.section == .authentication }
    }

    private var hidePasswordField: Bool {
        authSectionFields.contains { $0.hidesPassword && additionalFieldValues[$0.id] == "true" }
    }

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: String = ""
    @State private var database: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var type: DatabaseType = .mysql
    @State private var connectionURL: String = ""
    @State private var urlParseError: String?
    @State private var showURLImport = false
    @State private var hasLoadedData = false

    // SSH Configuration
    @State private var sshEnabled: Bool = false
    @State private var sshHost: String = ""
    @State private var sshPort: String = "22"
    @State private var sshUsername: String = ""
    @State private var sshPassword: String = ""
    @State private var sshAuthMethod: SSHAuthMethod = .password
    @State private var sshPrivateKeyPath: String = ""
    @State private var sshAgentSocketOption: SSHAgentSocketOption = .systemDefault
    @State private var customSSHAgentSocketPath: String = ""
    @State private var keyPassphrase: String = ""
    @State private var sshConfigEntries: [SSHConfigEntry] = []
    @State private var selectedSSHConfigHost: String = ""
    @State private var jumpHosts: [SSHJumpHost] = []
    @State private var totpMode: TOTPMode = .none
    @State private var totpSecret: String = ""
    @State private var totpAlgorithm: TOTPAlgorithm = .sha1
    @State private var totpDigits: Int = 6
    @State private var totpPeriod: Int = 30

    // SSL Configuration
    @State private var sslMode: SSLMode = .disabled
    @State private var sslCaCertPath: String = ""
    @State private var sslClientCertPath: String = ""
    @State private var sslClientKeyPath: String = ""

    // Color and Tag
    @State private var connectionColor: ConnectionColor = .none
    @State private var selectedTagId: UUID?
    @State private var selectedGroupId: UUID?

    // Safe mode level
    @State private var safeModeLevel: SafeModeLevel = .silent

    // AI policy
    @State private var aiPolicy: AIConnectionPolicy?

    // Plugin-driven additional connection fields
    @State private var additionalFieldValues: [String: String] = [:]

    // Startup commands
    @State private var startupCommands: String = ""

    // Pgpass
    @State private var pgpassStatus: PgpassStatus = .notChecked

    private var usePgpass: Bool {
        additionalFieldValues["usePgpass"] == "true"
    }

    // Pre-connect script
    @State private var preConnectScript: String = ""

    @State private var isTesting: Bool = false
    @State private var testSucceeded: Bool = false

    @State private var pluginInstallConnection: DatabaseConnection?

    // Tab selection
    @State private var selectedTab: FormTab = .general

    // Store original connection for editing
    @State private var originalConnection: DatabaseConnection?

    // MARK: - Enums

    private enum FormTab: String, CaseIterable {
        case general = "General"
        case ssh = "SSH Tunnel"
        case ssl = "SSL/TLS"
        case advanced = "Advanced"
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("", selection: $selectedTab) {
                ForEach(visibleTabs, id: \.rawValue) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            // Tab form content
            tabForm

            Divider()

            footer
        }
        .frame(width: 480, height: 520)
        .navigationTitle(
            isNew ? String(localized: "New Connection") : String(localized: "Edit Connection")
        )
        .onAppear {
            loadConnectionData()
            loadSSHConfig()
        }
        .onChange(of: type) { _, newType in
            if hasLoadedData {
                port = String(newType.defaultPort)
                additionalFieldValues = [:]
                for field in PluginManager.shared.additionalConnectionFields(for: newType) {
                    if let defaultValue = field.defaultValue {
                        additionalFieldValues[field.id] = defaultValue
                    }
                }
            }
            if !visibleTabs.contains(selectedTab) {
                selectedTab = .general
            }
        }
        .pluginInstallPrompt(connection: $pluginInstallConnection) { connection in
            connectAfterInstall(connection)
        }
        .onChange(of: additionalFieldValues) { _, _ in updatePgpassStatus() }
        .onChange(of: host) { _, _ in updatePgpassStatus() }
        .onChange(of: port) { _, _ in updatePgpassStatus() }
        .onChange(of: database) { _, _ in updatePgpassStatus() }
        .onChange(of: username) { _, _ in updatePgpassStatus() }
    }

    // MARK: - Tab Picker Helpers

    private var visibleTabs: [FormTab] {
        var tabs: [FormTab] = [.general]
        if PluginManager.shared.supportsSSH(for: type) {
            tabs.append(.ssh)
        }
        if PluginManager.shared.supportsSSL(for: type) {
            tabs.append(.ssl)
        }
        tabs.append(.advanced)
        return tabs
    }

    private var resolvedSSHAgentSocketPath: String {
        sshAgentSocketOption.resolvedPath(customPath: customSSHAgentSocketPath)
    }

    // MARK: - Tab Form Content

    @ViewBuilder
    private var tabForm: some View {
        switch selectedTab {
        case .general:
            generalForm
        case .ssh:
            sshForm
        case .ssl:
            sslForm
        case .advanced:
            advancedForm
        }
    }

    // MARK: - General Tab

    private var generalForm: some View {
        Form {
            Section {
                Picker(String(localized: "Type"), selection: $type) {
                    ForEach(availableDatabaseTypes) { t in
                        Label {
                            HStack {
                                Text(t.rawValue)
                                if t.isDownloadablePlugin && !PluginManager.shared.isDriverLoaded(for: t) {
                                    Image(systemName: "arrow.down.circle")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                            }
                        } icon: {
                            t.iconImage
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 20, height: 20)
                        }
                        .tag(t)
                    }
                }
                TextField(
                    String(localized: "Name"),
                    text: $name,
                    prompt: Text("Connection name")
                )
                Button {
                    showURLImport = true
                } label: {
                    Label(String(localized: "Import from URL"), systemImage: "link")
                }
            }

            if PluginManager.shared.connectionMode(for: type) == .fileBased {
                Section(String(localized: "Database File")) {
                    HStack {
                        TextField(
                            String(localized: "File Path"),
                            text: $database,
                            prompt: Text(filePathPrompt)
                        )
                        Button(String(localized: "Browse...")) { browseForFile() }
                            .controlSize(.small)
                    }
                }
            } else if PluginManager.shared.connectionMode(for: type) == .apiOnly {
                Section(String(localized: "Connection")) {
                    TextField(
                        String(localized: "Database"),
                        text: $database,
                        prompt: Text("database_name")
                    )
                }
            } else {
                Section(String(localized: "Connection")) {
                    TextField(
                        String(localized: "Host"),
                        text: $host,
                        prompt: Text("localhost")
                    )
                    TextField(
                        String(localized: "Port"),
                        text: $port,
                        prompt: Text(defaultPort)
                    )
                    if PluginManager.shared.requiresAuthentication(for: type) {
                        TextField(
                            String(localized: "Database"),
                            text: $database,
                            prompt: Text("database_name")
                        )
                    }
                }
            }

            if PluginManager.shared.connectionMode(for: type) != .fileBased {
                Section(String(localized: "Authentication")) {
                    if PluginManager.shared.requiresAuthentication(for: type)
                        && PluginManager.shared.connectionMode(for: type) != .apiOnly {
                        TextField(
                            String(localized: "Username"),
                            text: $username,
                            prompt: Text("root")
                        )
                    }
                    ForEach(authSectionFields, id: \.id) { field in
                        ConnectionFieldRow(
                            field: field,
                            value: Binding(
                                get: {
                                    additionalFieldValues[field.id]
                                        ?? field.defaultValue ?? ""
                                },
                                set: { additionalFieldValues[field.id] = $0 }
                            )
                        )
                    }
                    if !hidePasswordField {
                        let isApiOnly = PluginManager.shared.connectionMode(for: type) == .apiOnly
                        SecureField(
                            isApiOnly ? String(localized: "API Token") : String(localized: "Password"),
                            text: $password
                        )
                    }
                    if additionalFieldValues["usePgpass"] == "true" {
                        pgpassStatusView
                    }
                }
            }

            Section(String(localized: "Appearance")) {
                LabeledContent(String(localized: "Color")) {
                    ConnectionColorPicker(selectedColor: $connectionColor)
                }
                LabeledContent(String(localized: "Tag")) {
                    ConnectionTagEditor(selectedTagId: $selectedTagId)
                }
                LabeledContent(String(localized: "Group")) {
                    ConnectionGroupPicker(selectedGroupId: $selectedGroupId)
                }
                Picker(String(localized: "Safe Mode"), selection: $safeModeLevel) {
                    ForEach(SafeModeLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showURLImport) {
            connectionURLImportSheet
        }
    }

    // MARK: - Import from URL Sheet

    private var connectionURLImportSheet: some View {
        VStack(spacing: 16) {
            Text(String(localized: "Import from URL"))
                .font(.headline)

            Text(String(localized: "Paste a connection URL to auto-fill the form fields."))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField(
                String(localized: "Connection URL"),
                text: $connectionURL,
                prompt: Text("postgresql://user:password@host:5432/database")
            )
            .textFieldStyle(.roundedBorder)

            if let urlParseError {
                Text(urlParseError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(String(localized: "Cancel")) {
                    showURLImport = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(String(localized: "Import")) {
                    parseConnectionURL()
                    if urlParseError == nil && !connectionURL.isEmpty {
                        connectionURL = ""
                        urlParseError = nil
                        showURLImport = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(connectionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    @ViewBuilder
    private var pgpassStatusView: some View {
        switch pgpassStatus {
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
                systemImage: "xmark.circle.fill"
            )
            .foregroundStyle(.red)
            .font(.caption)
        case .matchFound:
            Label(
                String(localized: "~/.pgpass found — matching entry exists"),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            .font(.caption)
        case .noMatch:
            Label(
                String(localized: "~/.pgpass found — no matching entry"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.yellow)
            .font(.caption)
        }
    }

    // MARK: - SSH Tunnel Tab

    private var sshForm: some View {
        Form {
            Section {
                Toggle(String(localized: "Enable SSH Tunnel"), isOn: $sshEnabled)
            }

            if sshEnabled {
                Section(String(localized: "Server")) {
                    if !sshConfigEntries.isEmpty {
                        Picker(String(localized: "Config Host"), selection: $selectedSSHConfigHost)
                        {
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
                        TextField(
                            String(localized: "SSH Host"),
                            text: $sshHost,
                            prompt: Text("ssh.example.com")
                        )
                    }
                    TextField(
                        String(localized: "SSH Port"),
                        text: $sshPort,
                        prompt: Text("22")
                    )
                    TextField(
                        String(localized: "SSH User"),
                        text: $sshUsername,
                        prompt: Text("username")
                    )
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
                            TextField(
                                "Custom Path",
                                text: $customSSHAgentSocketPath,
                                prompt: Text("/path/to/agent.sock")
                            )
                        }
                        Text("Keys are provided by the SSH agent (e.g. 1Password, ssh-agent).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if sshAuthMethod == .keyboardInteractive {
                        SecureField(String(localized: "Password"), text: $sshPassword)
                        Text(
                            String(localized: "Password is sent via keyboard-interactive challenge-response.")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        LabeledContent(String(localized: "Key File")) {
                            HStack {
                                TextField(
                                    "", text: $sshPrivateKeyPath, prompt: Text("~/.ssh/id_rsa"))
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
                            Text(
                                String(
                                    localized:
                                        "You will be prompted for a verification code each time you connect."
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    DisclosureGroup(String(localized: "Jump Hosts")) {
                        ForEach($jumpHosts) { $jumpHost in
                            DisclosureGroup {
                                TextField(
                                    String(localized: "Host"),
                                    text: $jumpHost.host,
                                    prompt: Text("bastion.example.com")
                                )
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
                                    TextField(
                                        String(localized: "Username"),
                                        text: $jumpHost.username,
                                        prompt: Text("admin")
                                    )
                                }
                                Picker(String(localized: "Auth"), selection: $jumpHost.authMethod) {
                                    ForEach(SSHJumpAuthMethod.allCases) { method in
                                        Text(method.rawValue).tag(method)
                                    }
                                }
                                if jumpHost.authMethod == .privateKey {
                                    LabeledContent(String(localized: "Key File")) {
                                        HStack {
                                            TextField(
                                                "", text: $jumpHost.privateKeyPath,
                                                prompt: Text("~/.ssh/id_rsa"))
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
                                        withAnimation {
                                            jumpHosts.removeAll { $0.id == idToRemove }
                                        }
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .foregroundStyle(.red)
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

                        Text(
                            "Jump hosts are connected in order before reaching the SSH server above. Only key and agent auth are supported for jumps."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - SSL/TLS Tab

    private var sslForm: some View {
        Form {
            Section {
                Picker(String(localized: "SSL Mode"), selection: $sslMode) {
                    ForEach(SSLMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            }

            if sslMode != .disabled {
                Section {
                    Text(sslMode.description)
                        .foregroundStyle(.secondary)
                }

                if sslMode == .verifyCa || sslMode == .verifyIdentity {
                    Section(String(localized: "CA Certificate")) {
                        LabeledContent(String(localized: "CA Cert")) {
                            HStack {
                                TextField(
                                    "", text: $sslCaCertPath, prompt: Text("/path/to/ca-cert.pem"))
                                Button(String(localized: "Browse")) {
                                    browseForCertificate(binding: $sslCaCertPath)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }

                Section(String(localized: "Client Certificates (Optional)")) {
                    LabeledContent(String(localized: "Client Cert")) {
                        HStack {
                            TextField(
                                "", text: $sslClientCertPath,
                                prompt: Text(String(localized: "(optional)")))
                            Button(String(localized: "Browse")) {
                                browseForCertificate(binding: $sslClientCertPath)
                            }
                            .controlSize(.small)
                        }
                    }
                    LabeledContent(String(localized: "Client Key")) {
                        HStack {
                            TextField(
                                "", text: $sslClientKeyPath,
                                prompt: Text(String(localized: "(optional)")))
                            Button(String(localized: "Browse")) {
                                browseForCertificate(binding: $sslClientKeyPath)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Advanced Tab

    private var advancedForm: some View {
        Form {
            let advancedFields = additionalConnectionFields.filter { $0.section == .advanced }
            if !advancedFields.isEmpty {
                Section(type.displayName) {
                    ForEach(advancedFields, id: \.id) { field in
                        ConnectionFieldRow(
                            field: field,
                            value: Binding(
                                get: {
                                    additionalFieldValues[field.id]
                                        ?? field.defaultValue ?? ""
                                },
                                set: { additionalFieldValues[field.id] = $0 }
                            )
                        )
                    }
                }
            }

            Section(String(localized: "Startup Commands")) {
                StartupCommandsEditor(text: $startupCommands)
                    .frame(height: 80)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                Text(
                    "SQL commands to run after connecting, e.g. SET time_zone = 'Asia/Ho_Chi_Minh'. One per line or separated by semicolons."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(String(localized: "Pre-Connect Script")) {
                StartupCommandsEditor(text: $preConnectScript)
                    .frame(height: 80)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                Text(
                    "Shell script to run before connecting. Non-zero exit aborts connection."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(String(localized: "AI")) {
                Picker(String(localized: "AI Policy"), selection: $aiPolicy) {
                    Text(String(localized: "Use Default"))
                        .tag(AIConnectionPolicy?.none as AIConnectionPolicy?)
                    ForEach(AIConnectionPolicy.allCases) { policy in
                        Text(policy.displayName)
                            .tag(AIConnectionPolicy?.some(policy) as AIConnectionPolicy?)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Test connection
                Button(action: testConnection) {
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

                // Delete button (edit mode only)
                if !isNew {
                    Button("Delete", role: .destructive) {
                        Task {
                            let confirmed = await AlertHelper.confirmDestructive(
                                title: String(localized: "Delete Connection"),
                                message: String(localized: "Are you sure you want to delete this connection? This cannot be undone."),
                                confirmButton: String(localized: "Delete"),
                                window: NSApp.keyWindow
                            )
                            if confirmed {
                                deleteConnection()
                            }
                        }
                    }
                }

                // Cancel
                Button("Cancel") {
                    NSApplication.shared.closeWindows(withId: "connection-form")
                }

                // Save
                Button(isNew ? String(localized: "Create") : String(localized: "Save")) {
                    saveConnection()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand {
            NSApplication.shared.closeWindows(withId: "connection-form")
        }
        .onChange(of: host) { _, _ in testSucceeded = false }
        .onChange(of: port) { _, _ in testSucceeded = false }
        .onChange(of: username) { _, _ in testSucceeded = false }
        .onChange(of: password) { _, _ in testSucceeded = false }
        .onChange(of: database) { _, _ in testSucceeded = false }
        .onChange(of: type) { _, _ in testSucceeded = false }
        .onChange(of: sshEnabled) { _, _ in testSucceeded = false }
        .onChange(of: sshHost) { _, _ in testSucceeded = false }
        .onChange(of: sshPort) { _, _ in testSucceeded = false }
        .onChange(of: sshUsername) { _, _ in testSucceeded = false }
        .onChange(of: sshAuthMethod) { _, _ in testSucceeded = false }
        .onChange(of: sslMode) { _, _ in testSucceeded = false }
    }

    // MARK: - Helpers

    private var defaultPort: String {
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

    private var isValid: Bool {
        // Host and port can be empty (will use defaults: localhost and default port)
        let mode = PluginManager.shared.connectionMode(for: type)
        let requiresDatabase = mode == .fileBased || mode == .apiOnly
        var basicValid = !name.isEmpty && (requiresDatabase ? !database.isEmpty : true)
        if mode == .apiOnly {
            let hasRequiredFields = authSectionFields
                .filter(\.isRequired)
                .allSatisfy { !(additionalFieldValues[$0.id] ?? "").isEmpty }
            basicValid = basicValid && hasRequiredFields && !password.isEmpty
        }
        if sshEnabled {
            let sshPortValid = sshPort.isEmpty || (Int(sshPort).map { (1...65_535).contains($0) } ?? false)
            let sshValid = !sshHost.isEmpty && !sshUsername.isEmpty && sshPortValid
            let authValid =
                sshAuthMethod == .password || sshAuthMethod == .sshAgent
                || sshAuthMethod == .keyboardInteractive || !sshPrivateKeyPath.isEmpty
            let jumpValid = jumpHosts.allSatisfy(\.isValid)
            return basicValid && sshValid && authValid && jumpValid
        }
        return basicValid
    }

    private func updatePgpassStatus() {
        guard additionalFieldValues["usePgpass"] == "true" else {
            pgpassStatus = .notChecked
            return
        }
        pgpassStatus = PgpassStatus.check(
            host: host.isEmpty ? "localhost" : host,
            port: Int(port) ?? type.defaultPort,
            database: database,
            username: username.isEmpty ? "root" : username
        )
    }

    private func loadConnectionData() {
        // If editing, load from storage
        if let id = connectionId,
            let existing = storage.loadConnections().first(where: { $0.id == id })
        {
            originalConnection = existing
            name = existing.name
            host = existing.host
            port = existing.port > 0 ? String(existing.port) : ""
            database = existing.database
            username = existing.username
            type = existing.type

            // Load SSH configuration
            sshEnabled = existing.sshConfig.enabled
            sshHost = existing.sshConfig.host
            sshPort = String(existing.sshConfig.port)
            sshUsername = existing.sshConfig.username
            sshAuthMethod = existing.sshConfig.authMethod
            sshPrivateKeyPath = existing.sshConfig.privateKeyPath
            applySSHAgentSocketPath(existing.sshConfig.agentSocketPath)
            jumpHosts = existing.sshConfig.jumpHosts
            totpMode = existing.sshConfig.totpMode
            totpAlgorithm = existing.sshConfig.totpAlgorithm
            totpDigits = existing.sshConfig.totpDigits
            totpPeriod = existing.sshConfig.totpPeriod

            // Load SSL configuration
            sslMode = existing.sslConfig.mode
            sslCaCertPath = existing.sslConfig.caCertificatePath
            sslClientCertPath = existing.sslConfig.clientCertificatePath
            sslClientKeyPath = existing.sslConfig.clientKeyPath

            // Load color and tag
            connectionColor = existing.color
            selectedTagId = existing.tagId
            selectedGroupId = existing.groupId
            safeModeLevel = existing.safeModeLevel
            aiPolicy = existing.aiPolicy

            // Load additional fields from connection
            additionalFieldValues = existing.additionalFields

            // Migrate legacy redisDatabase to additionalFields
            if additionalFieldValues["redisDatabase"] == nil,
               let rdb = existing.redisDatabase {
                additionalFieldValues["redisDatabase"] = String(rdb)
            }

            for field in PluginManager.shared.additionalConnectionFields(for: existing.type) {
                if additionalFieldValues[field.id] == nil, let defaultValue = field.defaultValue {
                    additionalFieldValues[field.id] = defaultValue
                }
            }

            // Load startup commands
            startupCommands = existing.startupCommands ?? ""
            preConnectScript = existing.preConnectScript ?? ""

            // Load passwords from Keychain
            if let savedSSHPassword = storage.loadSSHPassword(for: existing.id) {
                sshPassword = savedSSHPassword
            }
            if let savedPassphrase = storage.loadKeyPassphrase(for: existing.id) {
                keyPassphrase = savedPassphrase
            }
            if let savedPassword = storage.loadPassword(for: existing.id) {
                password = savedPassword
            }
            if let savedTOTPSecret = storage.loadTOTPSecret(for: existing.id) {
                totpSecret = savedTOTPSecret
            }
        }
        Task { @MainActor in
            hasLoadedData = true
        }
    }

    private func saveConnection() {
        let sshConfig = SSHConfiguration(
            enabled: sshEnabled,
            host: sshHost,
            port: Int(sshPort) ?? 22,
            username: sshUsername,
            authMethod: sshAuthMethod,
            privateKeyPath: sshPrivateKeyPath,
            useSSHConfig: !selectedSSHConfigHost.isEmpty,
            agentSocketPath: resolvedSSHAgentSocketPath,
            jumpHosts: jumpHosts,
            totpMode: totpMode,
            totpAlgorithm: totpAlgorithm,
            totpDigits: totpDigits,
            totpPeriod: totpPeriod
        )

        let sslConfig = SSLConfiguration(
            mode: sslMode,
            caCertificatePath: sslCaCertPath,
            clientCertificatePath: sslClientCertPath,
            clientKeyPath: sslClientKeyPath
        )

        let finalHost = host.trimmingCharacters(in: .whitespaces).isEmpty ? "localhost" : host
        let finalPort = Int(port) ?? type.defaultPort
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)
        let finalUsername =
            trimmedUsername.isEmpty && PluginManager.shared.requiresAuthentication(for: type)
                ? "root" : trimmedUsername

        var finalAdditionalFields = additionalFieldValues
        let trimmedScript = preConnectScript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedScript.isEmpty {
            finalAdditionalFields["preConnectScript"] = preConnectScript
        } else {
            finalAdditionalFields.removeValue(forKey: "preConnectScript")
        }

        let connectionToSave = DatabaseConnection(
            id: connectionId ?? UUID(),
            name: name,
            host: finalHost,
            port: finalPort,
            database: database,
            username: finalUsername,
            type: type,
            sshConfig: sshConfig,
            sslConfig: sslConfig,
            color: connectionColor,
            tagId: selectedTagId,
            groupId: selectedGroupId,
            safeModeLevel: safeModeLevel,
            aiPolicy: aiPolicy,
            redisDatabase: additionalFieldValues["redisDatabase"].map { Int($0) ?? 0 },
            startupCommands: startupCommands.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : startupCommands,
            additionalFields: finalAdditionalFields.isEmpty ? nil : finalAdditionalFields
        )

        // Save passwords to Keychain
        if !password.isEmpty {
            storage.savePassword(password, for: connectionToSave.id)
        }
        if sshEnabled && (sshAuthMethod == .password || sshAuthMethod == .keyboardInteractive)
            && !sshPassword.isEmpty
        {
            storage.saveSSHPassword(sshPassword, for: connectionToSave.id)
        }
        if sshEnabled && sshAuthMethod == .privateKey && !keyPassphrase.isEmpty {
            storage.saveKeyPassphrase(keyPassphrase, for: connectionToSave.id)
        }
        if sshEnabled && totpMode == .autoGenerate && !totpSecret.isEmpty {
            storage.saveTOTPSecret(totpSecret, for: connectionToSave.id)
        } else {
            storage.deleteTOTPSecret(for: connectionToSave.id)
        }

        // Save to storage
        var savedConnections = storage.loadConnections()
        if isNew {
            savedConnections.append(connectionToSave)
            storage.saveConnections(savedConnections)
            SyncChangeTracker.shared.markDirty(.connection, id: connectionToSave.id.uuidString)
            // Close and connect to database
            NSApplication.shared.closeWindows(withId: "connection-form")
            connectToDatabase(connectionToSave)
        } else {
            if let index = savedConnections.firstIndex(where: { $0.id == connectionToSave.id }) {
                savedConnections[index] = connectionToSave
                storage.saveConnections(savedConnections)
                SyncChangeTracker.shared.markDirty(.connection, id: connectionToSave.id.uuidString)
            }
            NSApplication.shared.closeWindows(withId: "connection-form")
            NotificationCenter.default.post(name: .connectionUpdated, object: nil)
        }
    }

    private func deleteConnection() {
        guard let id = connectionId,
              let connection = storage.loadConnections().first(where: { $0.id == id }) else { return }
        storage.deleteConnection(connection)
        NSApplication.shared.closeWindows(withId: "connection-form")
        NotificationCenter.default.post(name: .connectionUpdated, object: nil)
    }

    private func connectToDatabase(_ connection: DatabaseConnection) {
        openWindow(id: "main", value: EditorTabPayload(connectionId: connection.id))
        NSApplication.shared.closeWindows(withId: "welcome")

        Task {
            do {
                try await dbManager.connectToSession(connection)
            } catch {
                if case PluginError.pluginNotInstalled = error {
                    Self.logger.info("Plugin not installed for \(connection.type.rawValue), prompting install")
                    handleMissingPlugin(connection: connection)
                } else {
                    Self.logger.error(
                        "Failed to connect: \(error.localizedDescription, privacy: .public)")
                    NSApplication.shared.closeWindows(withId: "main")
                    openWindow(id: "welcome")
                    AlertHelper.showErrorSheet(
                        title: String(localized: "Connection Failed"),
                        message: error.localizedDescription,
                        window: nil
                    )
                }
            }
        }
    }

    private func handleMissingPlugin(connection: DatabaseConnection) {
        NSApplication.shared.closeWindows(withId: "main")
        openWindow(id: "welcome")
        pluginInstallConnection = connection
    }

    private func connectAfterInstall(_ connection: DatabaseConnection) {
        openWindow(id: "main", value: EditorTabPayload(connectionId: connection.id))
        NSApplication.shared.closeWindows(withId: "welcome")

        Task {
            do {
                try await dbManager.connectToSession(connection)
            } catch {
                Self.logger.error(
                    "Failed to connect after plugin install: \(error.localizedDescription, privacy: .public)")
                NSApplication.shared.closeWindows(withId: "main")
                openWindow(id: "welcome")
                AlertHelper.showErrorSheet(
                    title: String(localized: "Connection Failed"),
                    message: error.localizedDescription,
                    window: nil
                )
            }
        }
    }

    func testConnection() {
        isTesting = true
        testSucceeded = false
        let window = NSApp.keyWindow

        // Build SSH config
        let sshConfig = SSHConfiguration(
            enabled: sshEnabled,
            host: sshHost,
            port: Int(sshPort) ?? 22,
            username: sshUsername,
            authMethod: sshAuthMethod,
            privateKeyPath: sshPrivateKeyPath,
            useSSHConfig: !selectedSSHConfigHost.isEmpty,
            agentSocketPath: resolvedSSHAgentSocketPath,
            jumpHosts: jumpHosts,
            totpMode: totpMode,
            totpAlgorithm: totpAlgorithm,
            totpDigits: totpDigits,
            totpPeriod: totpPeriod
        )

        let sslConfig = SSLConfiguration(
            mode: sslMode,
            caCertificatePath: sslCaCertPath,
            clientCertificatePath: sslClientCertPath,
            clientKeyPath: sslClientKeyPath
        )

        let finalHost = host.trimmingCharacters(in: .whitespaces).isEmpty ? "localhost" : host
        let finalPort = Int(port) ?? type.defaultPort
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)
        let finalUsername =
            trimmedUsername.isEmpty && PluginManager.shared.requiresAuthentication(for: type)
                ? "root" : trimmedUsername

        var finalAdditionalFields = additionalFieldValues
        let trimmedScript = preConnectScript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedScript.isEmpty {
            finalAdditionalFields["preConnectScript"] = preConnectScript
        } else {
            finalAdditionalFields.removeValue(forKey: "preConnectScript")
        }

        let testConn = DatabaseConnection(
            name: name,
            host: finalHost,
            port: finalPort,
            database: database,
            username: finalUsername,
            type: type,
            sshConfig: sshConfig,
            sslConfig: sslConfig,
            color: connectionColor,
            tagId: selectedTagId,
            groupId: selectedGroupId,
            redisDatabase: additionalFieldValues["redisDatabase"].map { Int($0) ?? 0 },
            startupCommands: startupCommands.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : startupCommands,
            additionalFields: finalAdditionalFields.isEmpty ? nil : finalAdditionalFields
        )

        Task {
            do {
                // Save passwords temporarily for test
                if !password.isEmpty {
                    ConnectionStorage.shared.savePassword(password, for: testConn.id)
                }
                if sshEnabled
                    && (sshAuthMethod == .password || sshAuthMethod == .keyboardInteractive)
                    && !sshPassword.isEmpty
                {
                    ConnectionStorage.shared.saveSSHPassword(sshPassword, for: testConn.id)
                }
                if sshEnabled && sshAuthMethod == .privateKey && !keyPassphrase.isEmpty {
                    ConnectionStorage.shared.saveKeyPassphrase(keyPassphrase, for: testConn.id)
                }
                if sshEnabled && totpMode == .autoGenerate && !totpSecret.isEmpty {
                    ConnectionStorage.shared.saveTOTPSecret(totpSecret, for: testConn.id)
                }

                let success = try await DatabaseManager.shared.testConnection(
                    testConn, sshPassword: sshPassword)
                ConnectionStorage.shared.deleteTOTPSecret(for: testConn.id)
                await MainActor.run {
                    isTesting = false
                    if success {
                        testSucceeded = true
                    } else {
                        AlertHelper.showErrorSheet(
                            title: String(localized: "Connection Test Failed"),
                            message: String(localized: "Connection test failed"),
                            window: window
                        )
                    }
                }
            } catch {
                ConnectionStorage.shared.deleteTOTPSecret(for: testConn.id)
                await MainActor.run {
                    isTesting = false
                    testSucceeded = false
                    if case PluginError.pluginNotInstalled = error {
                        pluginInstallConnection = testConn
                    } else {
                        AlertHelper.showErrorSheet(
                            title: String(localized: "Connection Test Failed"),
                            message: error.localizedDescription,
                            window: window
                        )
                    }
                }
            }
        }
    }

    private func browseForFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.database, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { response in
            if response == .OK, let url = panel.url {
                database = url.path(percentEncoded: false)
            }
        }
    }

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

    private func browseForCertificate(binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        panel.showsHiddenFiles = true

        panel.begin { response in
            if response == .OK, let url = panel.url {
                binding.wrappedValue = url.path(percentEncoded: false)
            }
        }
    }

    private func loadSSHConfig() {
        sshConfigEntries = SSHConfigParser.parse()
    }

    private func parseConnectionURL() {
        let trimmed = connectionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            urlParseError = nil
            return
        }

        switch ConnectionURLParser.parse(trimmed) {
        case .success(let parsed):
            urlParseError = nil
            type = parsed.type
            host = parsed.host
            port = parsed.port.map(String.init) ?? String(parsed.type.defaultPort)
            database = parsed.database
            username = parsed.username
            password = parsed.password
            sslMode = parsed.sslMode ?? .disabled
            if let sshHostValue = parsed.sshHost {
                sshEnabled = true
                sshHost = sshHostValue
                sshPort = parsed.sshPort.map(String.init) ?? "22"
                sshUsername = parsed.sshUsername ?? ""
                if parsed.usePrivateKey == true {
                    sshAuthMethod = .privateKey
                }
                if parsed.useSSHAgent == true {
                    sshAuthMethod = .sshAgent
                    applySSHAgentSocketPath(parsed.agentSocket ?? "")
                }
            }
            if let authSourceValue = parsed.authSource, !authSourceValue.isEmpty {
                additionalFieldValues["mongoAuthSource"] = authSourceValue
            }
            if parsed.type.pluginTypeId == "Redis", !parsed.database.isEmpty {
                additionalFieldValues["redisDatabase"] = parsed.database
            }
            if let connectionName = parsed.connectionName, !connectionName.isEmpty {
                name = connectionName
            } else if name.isEmpty {
                name = parsed.suggestedName
            }
        case .failure(let error):
            urlParseError = error.localizedDescription
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

// MARK: - Pgpass Status

private enum PgpassStatus {
    case notChecked
    case fileNotFound
    case badPermissions
    case matchFound
    case noMatch

    static func check(host: String, port: Int, database: String, username: String) -> PgpassStatus {
        guard PgpassReader.fileExists() else { return .fileNotFound }
        guard PgpassReader.filePermissionsAreValid() else { return .badPermissions }
        if PgpassReader.resolve(host: host, port: port, database: database, username: username) != nil {
            return .matchFound
        }
        return .noMatch
    }
}

// MARK: - Startup Commands Editor

private struct StartupCommandsEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isRichText = false
        textView.string = text
        textView.textContainerInset = NSSize(width: 2, height: 6)
        textView.drawsBackground = false
        textView.delegate = context.coordinator

        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

#Preview("New Connection") {
    ConnectionFormView(connectionId: nil)
}

#Preview("Edit Connection") {
    ConnectionFormView(connectionId: DatabaseConnection.sampleConnections[0].id)
}
