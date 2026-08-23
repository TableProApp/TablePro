import SwiftUI
import TableProDatabase
import TableProModels
import TableProOracleCore
import UniformTypeIdentifiers

struct ConnectionFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var viewModel: ConnectionFormViewModel
    @State private var activeFilePicker: ActiveFilePicker?
    @State private var pendingFilePicker: ActiveFilePicker?
    @State private var showNewDatabaseAlert = false
    @State private var hapticSuccess = false
    @State private var hapticError = false
    @State private var pasteTarget: CertificateRole?
    @State private var showPKCS12Password = false

    var onSave: (DatabaseConnection) -> Void

    enum ActiveFilePicker: Identifiable, Hashable {
        case sqliteDatabase
        case duckdbDatabase
        case sshKey
        case certificate(CertificateRole)
        case pkcs12
        var id: Int { hashValue }
    }

    init(editing connection: DatabaseConnection? = nil, onSave: @escaping (DatabaseConnection) -> Void) {
        _viewModel = State(wrappedValue: ConnectionFormViewModel(editing: connection))
        self.onSave = onSave
    }

    private var showFilePicker: Binding<Bool> {
        Binding(
            get: { activeFilePicker != nil },
            set: { if !$0 { activeFilePicker = nil } }
        )
    }

    private func present(_ picker: ActiveFilePicker) {
        pendingFilePicker = picker
        activeFilePicker = picker
    }

    private var showCertificateError: Binding<Bool> {
        Binding(
            get: { viewModel.certificateError != nil },
            set: { if !$0 { viewModel.dismissCertificateError() } }
        )
    }

    private var showCredentialError: Binding<Bool> {
        Binding(
            get: { viewModel.credentialError != nil },
            set: { if !$0 { viewModel.dismissCredentialError() } }
        )
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        return NavigationStack {
            Form {
                connectionSection(viewModel: viewModel)
                organizationSection(viewModel: viewModel)

                if viewModel.type == .sqlite {
                    sqliteSection(viewModel: viewModel)
                } else if viewModel.type == .duckdb {
                    duckDBSection(viewModel: viewModel)
                } else {
                    serverSection(viewModel: viewModel)
                }

                if viewModel.type == .oracle {
                    oracleSection(viewModel: viewModel)
                }

                if !viewModel.isFileBased {
                    Section {
                        if viewModel.type == .oracle {
                            Picker(String(localized: "SSL Mode"), selection: $viewModel.oracleSSLMode) {
                                Text(String(localized: "Disabled")).tag(SSLConfiguration.SSLMode.disable)
                                Text(String(localized: "Required")).tag(SSLConfiguration.SSLMode.require)
                                Text(String(localized: "Verify CA")).tag(SSLConfiguration.SSLMode.verifyCa)
                                Text(String(localized: "Verify Identity")).tag(SSLConfiguration.SSLMode.verifyFull)
                            }
                        } else if viewModel.type == .mssql {
                            // FreeTDS db-lib only honors on/off encryption (DBSETENCRYPT). Per-connection
                            // cert chain verification is not exposed, so only Disabled and Required are listed.
                            // See Plugins/MSSQLDriverPlugin/MSSQLSSLMapping.swift for the FreeTDS contract.
                            Picker(String(localized: "SSL Mode"), selection: $viewModel.mssqlSSLMode) {
                                Text(String(localized: "Disabled")).tag(SSLConfiguration.SSLMode.disable)
                                Text(String(localized: "Required")).tag(SSLConfiguration.SSLMode.require)
                            }
                        }
                    }
                    if viewModel.usesCertificateSection {
                        ConnectionSSLSection(
                            viewModel: viewModel,
                            onChooseFile: { present(.certificate($0)) },
                            onChoosePKCS12: { present(.pkcs12) },
                            onPaste: { pasteTarget = $0 }
                        )
                    }
                    sshSection(viewModel: viewModel)
                }

                testSection
            }
            .scrollDismissesKeyboard(.interactively)
            .task {
                viewModel.loadCertificateSummaries()
                await viewModel.loadStoredCredentials(secureStore: appState.secureStore)
            }
            .navigationTitle(viewModel.isEditing ? String(localized: "Edit Connection") : String(localized: "New Connection"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ConfirmButton(title: "Save", action: handleSave)
                        .disabled(!viewModel.canSave)
                }
            }
            .fileImporter(
                isPresented: showFilePicker,
                allowedContentTypes: contentTypes(for: activeFilePicker),
                allowsMultipleSelection: false
            ) { result in
                let picker = pendingFilePicker
                pendingFilePicker = nil
                switch picker {
                case .sqliteDatabase: viewModel.handleSQLiteFilePicker(result)
                case .duckdbDatabase: viewModel.handleDuckDBFilePicker(result)
                case .sshKey: viewModel.handleSSHKeyFilePicker(result)
                case .certificate(let role): viewModel.importCertificateFile(result, role: role)
                case .pkcs12:
                    viewModel.stagePKCS12(result)
                    showPKCS12Password = viewModel.pendingPKCS12 != nil
                case nil: break
                }
            }
            .sheet(item: $pasteTarget) { role in
                CertificatePasteSheet(viewModel: viewModel, role: role)
            }
            .alert("Certificate Password", isPresented: $showPKCS12Password) {
                SecureField("Password", text: $viewModel.pkcs12Password)
                Button("Import") { viewModel.importPKCS12() }
                Button("Cancel", role: .cancel) { viewModel.cancelPKCS12() }
            } message: {
                Text("Enter the password used when the certificate file was exported.")
            }
            .alert("Certificate", isPresented: showCertificateError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.certificateError ?? "")
            }
            .alert("New Database", isPresented: $showNewDatabaseAlert) {
                TextField("Database name", text: $viewModel.newDatabaseName)
                Button("Create") { viewModel.createNewDatabase() }
                Button("Cancel", role: .cancel) { viewModel.newDatabaseName = "" }
            } message: {
                Text("Enter a name for the new database file.")
            }
            .alert("Keychain Warning", isPresented: showCredentialError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.credentialError ?? String(localized: "Failed to save credentials."))
            }
            .sensoryFeedback(.success, trigger: hapticSuccess)
            .sensoryFeedback(.error, trigger: hapticError)
        }
    }

    // MARK: - Connection Section

    @ViewBuilder
    private func connectionSection(viewModel: ConnectionFormViewModel) -> some View {
        @Bindable var viewModel = viewModel
        Section("Connection") {
            TextField("Name", text: $viewModel.name)
                .textInputAutocapitalization(.never)

            Picker("Database Type", selection: $viewModel.type) {
                ForEach(DatabaseType.mobileSupportedTypes, id: \.rawValue) { dbType in
                    Label {
                        Text(dbType.mobileDisplayName)
                    } icon: {
                        Image(dbType.iconName)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                    }
                    .tag(dbType)
                }
            }
        }
    }

    @ViewBuilder
    private func organizationSection(viewModel: ConnectionFormViewModel) -> some View {
        @Bindable var viewModel = viewModel
        Section("Organization") {
            Picker("Group", selection: $viewModel.groupId) {
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

            Picker("Tag", selection: $viewModel.tagId) {
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

            Picker("Safe Mode", selection: $viewModel.safeModeLevel) {
                ForEach(SafeModeLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: - SQLite Section

    @ViewBuilder
    private func sqliteSection(viewModel: ConnectionFormViewModel) -> some View {
        Section("Database File") {
            if let url = viewModel.selectedFileURL {
                selectedFileRow(url, viewModel: viewModel)
            }

            Button {
                pendingFilePicker = .sqliteDatabase
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

    // MARK: - DuckDB Section

    @ViewBuilder
    private func duckDBSection(viewModel: ConnectionFormViewModel) -> some View {
        @Bindable var viewModel = viewModel
        Section("Mode") {
            Toggle("In-Memory Database", isOn: $viewModel.duckDBInMemory)
        }

        if !viewModel.duckDBInMemory {
            Section("Database File") {
                if let url = viewModel.selectedFileURL {
                    selectedFileRow(url, viewModel: viewModel)
                }

                Button {
                    pendingFilePicker = .duckdbDatabase
                    activeFilePicker = .duckdbDatabase
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
    }

    @ViewBuilder
    private func selectedFileRow(_ url: URL, viewModel: ConnectionFormViewModel) -> some View {
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
                viewModel.clearSelectedFile()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Server Section

    @ViewBuilder
    private func oracleSection(viewModel: ConnectionFormViewModel) -> some View {
        @Bindable var viewModel = viewModel
        Section("Oracle") {
            Picker(String(localized: "Connect Using"), selection: $viewModel.oracleConnectionType) {
                Text(String(localized: "Service Name")).tag(OracleConnectionOptions.IdentifierMode.service)
                Text("SID").tag(OracleConnectionOptions.IdentifierMode.sid)
            }
            .pickerStyle(.segmented)

            if viewModel.oracleConnectionType == .service {
                TextField("Service Name", text: $viewModel.oracleServiceName, prompt: Text(verbatim: "ORCL"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
            } else {
                TextField("SID", text: $viewModel.oracleSID, prompt: Text(verbatim: "XE"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
            }

            Picker(String(localized: "Role"), selection: $viewModel.oracleRole) {
                Text(String(localized: "Normal")).tag(OracleConnectionOptions.Role.normal)
                Text(verbatim: "SYSDBA").tag(OracleConnectionOptions.Role.sysdba)
                Text(verbatim: "SYSOPER").tag(OracleConnectionOptions.Role.sysoper)
            }
        }
    }

    @ViewBuilder
    private func serverSection(viewModel: ConnectionFormViewModel) -> some View {
        @Bindable var viewModel = viewModel
        Section {
            TextField("Host", text: $viewModel.host)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            TextField("Port", text: $viewModel.port)
                .keyboardType(.numberPad)
            TextField("Username", text: $viewModel.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
            SecureField("Password", text: $viewModel.password)
        } header: {
            Text("Server")
        } footer: {
            if viewModel.type == .redis {
                Text("Username is for Redis 6 and later ACL users. Leave it empty for password-only servers.")
            }
        }
        Section("Database") {
            TextField("Database Name", text: $viewModel.database)
                .textInputAutocapitalization(.never)
        }
    }

    // MARK: - SSH Section

    @ViewBuilder
    private func sshSection(viewModel: ConnectionFormViewModel) -> some View {
        @Bindable var viewModel = viewModel
        Section {
            Toggle("SSH Tunnel", isOn: $viewModel.sshEnabled)
        }

        if viewModel.sshEnabled {
            Section("SSH Server") {
                TextField("SSH Host", text: $viewModel.sshHost)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                TextField("SSH Port", text: $viewModel.sshPort)
                    .keyboardType(.numberPad)
                TextField("SSH Username", text: $viewModel.sshUsername)
                    .textInputAutocapitalization(.never)

                Picker("Auth Method", selection: $viewModel.sshAuthMethod) {
                    Text("Password").tag(SSHConfiguration.SSHAuthMethod.password)
                    Text("Private Key").tag(SSHConfiguration.SSHAuthMethod.privateKey)
                }
                .pickerStyle(.segmented)
            }

            if viewModel.sshAuthMethod == .password {
                Section("SSH Password") {
                    SecureField("Password", text: $viewModel.sshPassword)
                }
            } else {
                privateKeySection(viewModel: viewModel)
            }
        }
    }

    @ViewBuilder
    private func privateKeySection(viewModel: ConnectionFormViewModel) -> some View {
        @Bindable var viewModel = viewModel
        Section("Private Key") {
            Picker("Input Method", selection: $viewModel.sshKeyInputMode) {
                ForEach(ConnectionFormViewModel.KeyInputMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if viewModel.sshKeyInputMode == .file {
                Button {
                    pendingFilePicker = .sshKey
                    activeFilePicker = .sshKey
                } label: {
                    HStack {
                        if viewModel.sshKeyPath.isEmpty {
                            Text("Select Private Key")
                        } else {
                            Text(verbatim: URL(fileURLWithPath: viewModel.sshKeyPath).lastPathComponent)
                        }
                        Spacer()
                        Image(systemName: "folder")
                    }
                }
            } else {
                TextEditor(text: $viewModel.sshKeyContent)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 120)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .overlay(alignment: .topLeading) {
                        if viewModel.sshKeyContent.isEmpty {
                            Text("Paste private key (PEM format)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                    }
            }

            SecureField("Passphrase (optional)", text: $viewModel.sshKeyPassphrase)
        }
    }

    // MARK: - Test Section

    private var testSection: some View {
        Section {
            Button {
                Task { await handleTest() }
            } label: {
                HStack {
                    if viewModel.isTesting {
                        ProgressView()
                            .controlSize(.small)
                        Text("Testing...")
                    } else {
                        Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                    }
                }
            }
            .disabled(viewModel.isTesting || !viewModel.canSave)

            if let testResult = viewModel.testResult {
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
                    if let suggested = testResult.suggestedOracleMode {
                        Button(suggested == .sid
                            ? String(localized: "Use SID Instead")
                            : String(localized: "Use Service Name Instead")) {
                            viewModel.oracleConnectionType = suggested
                            Task { await handleTest() }
                        }
                        .font(.caption)
                        .padding(.leading, 28)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func handleTest() async {
        await viewModel.testConnection(appState: appState, secureStore: appState.secureStore)
        if let result = viewModel.testResult {
            if result.success { hapticSuccess.toggle() } else { hapticError.toggle() }
        }
    }

    private func handleSave() {
        guard let connection = viewModel.save(appState: appState, secureStore: appState.secureStore) else { return }
        onSave(connection)
    }

    // MARK: - Helpers

    private func contentTypes(for picker: ActiveFilePicker?) -> [UTType] {
        switch picker {
        case .sqliteDatabase: return sqliteContentTypes
        case .duckdbDatabase: return duckDBContentTypes
        case .certificate: return certificateContentTypes
        case .pkcs12: return pkcs12ContentTypes
        default: return [.data]
        }
    }

    private var certificateContentTypes: [UTType] {
        [UTType.x509Certificate, .text, .data]
    }

    private var pkcs12ContentTypes: [UTType] {
        let extensions = ["p12", "pfx"]
        return [UTType.pkcs12] + extensions.compactMap { UTType(filenameExtension: $0) } + [.data]
    }

    private var sqliteContentTypes: [UTType] {
        let extensions = ["db", "db3", "s3db", "sl3", "sqlite", "sqlite3", "sqlitedb"]
        return [UTType.database] + extensions.compactMap { UTType(filenameExtension: $0) } + [.data]
    }

    private var duckDBContentTypes: [UTType] {
        let extensions = ["duckdb", "ddb"]
        return extensions.compactMap { UTType(filenameExtension: $0) } + [.data]
    }
}
