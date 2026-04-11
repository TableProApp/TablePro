//
//  ConnectionFormView.swift
//  TableProMobile
//

import os
import SwiftUI
import TableProDatabase
import TableProModels
import UniformTypeIdentifiers

struct ConnectionFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var name = ""
    @State private var type: DatabaseType = .mysql
    @State private var host = "127.0.0.1"
    @State private var port = "3306"
    @State private var username = ""
    @State private var password = ""
    @State private var database = ""
    @State private var sslEnabled = false

    // File pickers
    enum ActiveFilePicker: Identifiable {
        case sqliteDatabase
        case sshKey
        var id: Int { hashValue }
    }
    @State private var activeFilePicker: ActiveFilePicker?
    @State private var selectedFileURL: URL?
    @State private var showNewDatabaseAlert = false
    @State private var newDatabaseName = ""

    // Organization
    @State private var groupId: UUID?
    @State private var tagId: UUID?
    @State private var safeModeLevel: SafeModeLevel = .off

    // SSH
    @State private var sshEnabled = false
    @State private var sshHost = ""
    @State private var sshPort = "22"
    @State private var sshUsername = ""
    @State private var sshPassword = ""
    @State private var sshAuthMethod: SSHConfiguration.SSHAuthMethod = .password
    @State private var sshKeyPath = ""
    @State private var sshKeyContent = ""
    @State private var sshKeyPassphrase = ""
    @State private var sshKeyInputMode = KeyInputMode.file
    private var showFilePicker: Binding<Bool> {
        Binding(
            get: { activeFilePicker != nil },
            set: { if !$0 { activeFilePicker = nil } }
        )
    }

    enum KeyInputMode: String, CaseIterable {
        case file = "Import File"
        case paste = "Paste Key"
    }

    // Test connection
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var credentialError: String?
    @State private var showCredentialError = false
    @State private var hapticSuccess = false
    @State private var hapticError = false

    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionFormView")

    private let existingConnection: DatabaseConnection?
    var onSave: (DatabaseConnection) -> Void

    private let databaseTypes: [(DatabaseType, String)] = [
        (.mysql, "MySQL"),
        (.mariadb, "MariaDB"),
        (.postgresql, "PostgreSQL"),
        (.sqlite, "SQLite"),
        (.redis, "Redis"),
    ]

    init(editing connection: DatabaseConnection? = nil, onSave: @escaping (DatabaseConnection) -> Void) {
        self.existingConnection = connection
        self.onSave = onSave
        if let connection {
            _name = State(initialValue: connection.name)
            _type = State(initialValue: connection.type)
            _host = State(initialValue: connection.host)
            _port = State(initialValue: String(connection.port))
            _username = State(initialValue: connection.username)
            _database = State(initialValue: connection.database)
            _sslEnabled = State(initialValue: connection.sslEnabled)
            _sshEnabled = State(initialValue: connection.sshEnabled)
            if let ssh = connection.sshConfiguration {
                _sshHost = State(initialValue: ssh.host)
                _sshPort = State(initialValue: String(ssh.port))
                _sshUsername = State(initialValue: ssh.username)
                _sshAuthMethod = State(initialValue: ssh.authMethod)
                _sshKeyPath = State(initialValue: ssh.privateKeyPath ?? "")
                _sshKeyContent = State(initialValue: ssh.privateKeyData ?? "")
                if let keyData = ssh.privateKeyData, !keyData.isEmpty {
                    _sshKeyInputMode = State(initialValue: .paste)
                }
            }
            _groupId = State(initialValue: connection.groupId)
            _tagId = State(initialValue: connection.tagId)
            _safeModeLevel = State(initialValue: connection.safeModeLevel)
            if connection.type == .sqlite {
                _selectedFileURL = State(initialValue: URL(fileURLWithPath: connection.database))
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)

                    Picker("Database Type", selection: $type) {
                        ForEach(databaseTypes, id: \.0.rawValue) { dbType, label in
                            Text(label).tag(dbType)
                        }
                    }
                    .onChange(of: type) { _, newType in
                        updateDefaultPort(for: newType)
                        selectedFileURL = nil
                        database = ""
                    }
                }

                Section("Organization") {
                    Picker("Group", selection: $groupId) {
                        Text("None").tag(UUID?.none)
                        ForEach(appState.groups) { group in
                            HStack {
                                Circle()
                                    .fill(ConnectionColorPicker.swiftUIColor(for: group.color))
                                    .frame(width: 8, height: 8)
                                Text(group.name)
                            }
                            .tag(Optional(group.id))
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Tag", selection: $tagId) {
                        Text("None").tag(UUID?.none)
                        ForEach(appState.tags) { tag in
                            HStack {
                                Circle()
                                    .fill(ConnectionColorPicker.swiftUIColor(for: tag.color))
                                    .frame(width: 8, height: 8)
                                Text(tag.name)
                            }
                            .tag(Optional(tag.id))
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("Safe Mode", selection: $safeModeLevel) {
                        ForEach(SafeModeLevel.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .pickerStyle(.menu)
                }

                if type == .sqlite {
                    sqliteSection
                } else {
                    serverSection
                }

                if type != .sqlite {
                    Section {
                        Toggle("SSL", isOn: $sslEnabled)
                    }
                }

                if type != .sqlite {
                    sshSection
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            if isTesting {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Testing...")
                            } else {
                                Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                            }
                        }
                    }
                    .disabled(isTesting || !canSave)

                    if let testResult {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Image(systemName: testResult.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(testResult.success ? .green : .red)
                                Text(verbatim: testResult.message)
                                    .font(.footnote)
                                    .foregroundStyle(testResult.success ? .green : .red)
                            }
                            if let recovery = testResult.recovery {
                                Text(verbatim: recovery)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 28)
                            }
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                if let conn = existingConnection {
                    let connKey = "com.TablePro.password.\(conn.id.uuidString)"
                    if let stored = try? appState.secureStore.retrieve(forKey: connKey), !stored.isEmpty {
                        password = stored
                    }
                    if let sshPwd = try? appState.secureStore.retrieve(forKey: "com.TablePro.sshpassword.\(conn.id.uuidString)"), !sshPwd.isEmpty {
                        sshPassword = sshPwd
                    }
                    if let passphrase = try? appState.secureStore.retrieve(forKey: "com.TablePro.keypassphrase.\(conn.id.uuidString)"), !passphrase.isEmpty {
                        sshKeyPassphrase = passphrase
                    }
                }
            }
            .navigationTitle(existingConnection != nil ? String(localized: "Edit Connection") : String(localized: "New Connection"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .fileImporter(
                isPresented: showFilePicker,
                allowedContentTypes: activeFilePicker == .sqliteDatabase ? sqliteContentTypes : [.data],
                allowsMultipleSelection: false
            ) { result in
                let picker = activeFilePicker
                activeFilePicker = nil
                switch picker {
                case .sqliteDatabase:
                    handleFilePickerResult(result)
                case .sshKey:
                    if case .success(let urls) = result, let url = urls.first {
                        guard url.startAccessingSecurityScopedResource() else { return }
                        defer { url.stopAccessingSecurityScopedResource() }
                        if let content = try? String(contentsOf: url, encoding: .utf8) {
                            sshKeyContent = content
                            sshKeyInputMode = .paste
                        } else {
                            guard let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
                            let dest = docsDir.appendingPathComponent("ssh_" + url.lastPathComponent)
                            try? FileManager.default.removeItem(at: dest)
                            try? FileManager.default.copyItem(at: url, to: dest)
                            sshKeyPath = dest.path
                        }
                    }
                case nil:
                    break
                }
            }
            .alert("New Database", isPresented: $showNewDatabaseAlert) {
                TextField("Database name", text: $newDatabaseName)
                Button("Create") { createNewDatabase() }
                Button("Cancel", role: .cancel) { newDatabaseName = "" }
            } message: {
                Text("Enter a name for the new SQLite database.")
            }
            .sensoryFeedback(.success, trigger: hapticSuccess)
            .sensoryFeedback(.error, trigger: hapticError)
            .alert("Keychain Warning", isPresented: $showCredentialError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(credentialError ?? "Failed to save credentials.")
            }
        }
    }

    // MARK: - SQLite Section

    private var sqliteSection: some View {
        Section("Database File") {
            if let url = selectedFileURL {
                HStack {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text(url.lastPathComponent)
                            .font(.body)
                        Text(url.deletingLastPathComponent().lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        selectedFileURL = nil
                        database = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                activeFilePicker = .sqliteDatabase
            } label: {
                Label("Open Database File", systemImage: "folder")
            }

            Button {
                showNewDatabaseAlert = true
            } label: {
                Label("Create New Database", systemImage: "plus.circle")
            }
        }
    }

    // MARK: - Server Section (MySQL, PostgreSQL, Redis)

    private var serverSection: some View {
        Group {
            Section("Server") {
                TextField("Host", text: $host)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)

                TextField("Port", text: $port)
                    .keyboardType(.numberPad)

                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)

                SecureField("Password", text: $password)
            }

            Section("Database") {
                TextField("Database Name", text: $database)
                    .textInputAutocapitalization(.never)
            }
        }
    }

    // MARK: - SSH Section

    @ViewBuilder
    private var sshSection: some View {
        Section {
            Toggle("SSH Tunnel", isOn: $sshEnabled)
        }

        if sshEnabled {
            Section("SSH Server") {
                TextField("SSH Host", text: $sshHost)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                TextField("SSH Port", text: $sshPort)
                    .keyboardType(.numberPad)
                TextField("SSH Username", text: $sshUsername)
                    .textInputAutocapitalization(.never)

                Picker("Auth Method", selection: $sshAuthMethod) {
                    Text("Password").tag(SSHConfiguration.SSHAuthMethod.password)
                    Text("Private Key").tag(SSHConfiguration.SSHAuthMethod.privateKey)
                }
                .pickerStyle(.segmented)
            }

            if sshAuthMethod == .password {
                Section("SSH Password") {
                    SecureField("Password", text: $sshPassword)
                }
            } else {
                Section("Private Key") {
                    Picker("Input Method", selection: $sshKeyInputMode) {
                        ForEach(KeyInputMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if sshKeyInputMode == .file {
                        Button {
                            activeFilePicker = .sshKey
                        } label: {
                            HStack {
                                Text(sshKeyPath.isEmpty
                                    ? "Select Private Key"
                                    : URL(fileURLWithPath: sshKeyPath).lastPathComponent)
                                Spacer()
                                Image(systemName: "folder")
                            }
                        }
                    } else {
                        TextEditor(text: $sshKeyContent)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 120)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .overlay(alignment: .topLeading) {
                                if sshKeyContent.isEmpty {
                                    Text("Paste private key (PEM format)")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .padding(.top, 8)
                                        .padding(.leading, 4)
                                        .allowsHitTesting(false)
                                }
                            }
                    }

                    SecureField("Passphrase (optional)", text: $sshKeyPassphrase)
                }
            }
        }
    }

    // MARK: - Logic

    private var canSave: Bool {
        if type == .sqlite {
            return !database.isEmpty
        }
        return !host.isEmpty
    }

    private var sqliteContentTypes: [UTType] {
        [UTType.database, UTType(filenameExtension: "sqlite3") ?? .data, .data]
    }

    private func updateDefaultPort(for type: DatabaseType) {
        switch type {
        case .mysql, .mariadb: port = "3306"
        case .postgresql: port = "5432"
        case .redshift: port = "5439"
        case .redis: port = "6379"
        case .sqlite: port = ""
        default: port = "3306"
        }
    }

    private func handleFilePickerResult(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        let destURL = copyToDocuments(url)
        selectedFileURL = destURL
        database = destURL.path
        if name.isEmpty {
            name = destURL.deletingPathExtension().lastPathComponent
        }
    }

    private func copyToDocuments(_ sourceURL: URL) -> URL {
        guard let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return sourceURL
        }
        var destURL = documentsDir.appendingPathComponent(sourceURL.lastPathComponent)

        if FileManager.default.fileExists(atPath: destURL.path) {
            let name = sourceURL.deletingPathExtension().lastPathComponent
            let ext = sourceURL.pathExtension
            let suffix = UUID().uuidString.prefix(8)
            destURL = documentsDir.appendingPathComponent("\(name)_\(suffix).\(ext)")
        }

        try? FileManager.default.copyItem(at: sourceURL, to: destURL)
        return destURL
    }

    private func createNewDatabase() {
        guard !newDatabaseName.isEmpty else { return }

        let safeName = newDatabaseName.hasSuffix(".db") ? newDatabaseName : "\(newDatabaseName).db"
        guard let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let fileURL = documentsDir.appendingPathComponent(safeName)

        selectedFileURL = fileURL
        database = fileURL.path
        if name.isEmpty {
            name = newDatabaseName
        }
        newDatabaseName = ""
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil

        let tempId = UUID()
        var testConn = buildConnection()
        testConn.id = tempId

        if !password.isEmpty {
            try? appState.connectionManager.storePassword(password, for: tempId)
        }

        let secureStore = KeychainSecureStore()
        if sshEnabled && !sshPassword.isEmpty {
            try? secureStore.store(sshPassword, forKey: "com.TablePro.sshpassword.\(tempId.uuidString)")
        }
        if sshEnabled && !sshKeyPassphrase.isEmpty {
            try? secureStore.store(sshKeyPassphrase, forKey: "com.TablePro.keypassphrase.\(tempId.uuidString)")
        }

        defer {
            try? appState.connectionManager.deletePassword(for: tempId)
            try? secureStore.delete(forKey: "com.TablePro.sshpassword.\(tempId.uuidString)")
            try? secureStore.delete(forKey: "com.TablePro.keypassphrase.\(tempId.uuidString)")
            isTesting = false
        }

        await appState.sshProvider.setPendingConnectionId(tempId)

        do {
            _ = try await appState.connectionManager.connect(testConn)
            await appState.connectionManager.disconnect(tempId)
            testResult = TestResult(success: true, message: String(localized: "Connection successful"), recovery: nil)
            hapticSuccess.toggle()
        } catch {
            let context = ErrorContext(
                operation: "testConnection",
                databaseType: type,
                host: host,
                sshEnabled: sshEnabled
            )
            let classified = ErrorClassifier.classify(error, context: context)
            testResult = TestResult(success: false, message: classified.message, recovery: classified.recovery)
            hapticError.toggle()
        }
    }

    private func buildConnection() -> DatabaseConnection {
        var conn = DatabaseConnection(
            id: existingConnection?.id ?? UUID(),
            name: name.isEmpty ? (selectedFileURL?.lastPathComponent ?? host) : name,
            type: type,
            host: host,
            port: Int(port) ?? 3306, // swiftlint:disable:this number_separator
            username: username,
            database: database,
            sshEnabled: sshEnabled,
            sslEnabled: sslEnabled,
            groupId: groupId,
            tagId: tagId
        )
        conn.safeModeLevel = safeModeLevel
        if sshEnabled {
            conn.sshConfiguration = SSHConfiguration(
                host: sshHost,
                port: Int(sshPort) ?? 22,
                username: sshUsername,
                authMethod: sshAuthMethod,
                privateKeyPath: sshKeyPath.isEmpty ? nil : sshKeyPath,
                privateKeyData: sshKeyContent.isEmpty ? nil : sshKeyContent
            )
        }
        return conn
    }

    private func save() {
        let connection = buildConnection()
        var storageFailed = false

        if !password.isEmpty {
            do {
                try appState.connectionManager.storePassword(password, for: connection.id)
            } catch {
                Self.logger.error("Failed to store password: \(error.localizedDescription, privacy: .public)")
                storageFailed = true
            }
        }

        if sshEnabled {
            let secureStore = KeychainSecureStore()

            if !sshPassword.isEmpty {
                do {
                    try secureStore.store(sshPassword, forKey: "com.TablePro.sshpassword.\(connection.id.uuidString)")
                } catch {
                    Self.logger.error("Failed to store SSH password: \(error.localizedDescription, privacy: .public)")
                    storageFailed = true
                }
            }
            if !sshKeyPassphrase.isEmpty {
                do {
                    try secureStore.store(sshKeyPassphrase, forKey: "com.TablePro.keypassphrase.\(connection.id.uuidString)")
                } catch {
                    Self.logger.error("Failed to store SSH key passphrase: \(error.localizedDescription, privacy: .public)")
                    storageFailed = true
                }
            }
            if !sshKeyContent.isEmpty {
                do {
                    try secureStore.store(sshKeyContent, forKey: "com.TablePro.sshkeydata.\(connection.id.uuidString)")
                } catch {
                    Self.logger.error("Failed to store SSH key data: \(error.localizedDescription, privacy: .public)")
                    storageFailed = true
                }
            }
        }

        if storageFailed {
            credentialError = String(localized: "Some credentials could not be saved to the keychain. You may need to re-enter them later.")
            showCredentialError = true
            return
        }

        onSave(connection)
    }
}

private struct TestResult {
    let success: Bool
    let message: String
    let recovery: String?
}
