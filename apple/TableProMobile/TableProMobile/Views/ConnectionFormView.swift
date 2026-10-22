import SwiftUI
import TableProConnectionLibrary
import TableProDatabase
import TableProModels
import TableProOracleCore
import TableProSSHTransport
import UniformTypeIdentifiers

struct ConnectionFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(ConnectionCoordinatorStore.self) private var coordinatorStore

    @State private var viewModel: ConnectionFormViewModel
    @State private var activeFilePicker: ActiveFilePicker?
    @State private var pendingFilePicker: ActiveFilePicker?
    @State private var showNewDatabaseAlert = false
    @State private var hapticSuccess = false
    @State private var hapticError = false
    @State private var pasteTarget: CertificateRole?
    @State private var showPKCS12Password = false
    @State private var pastingServiceAccountKey = false
    @State private var pushedJumpHostId: UUID?
    @State private var reconnectingConnectionName: String?

    var onSaved: (UUID) -> Void

    enum ActiveFilePicker: Identifiable, Hashable {
        case sqliteDatabase
        case duckdbDatabase
        case sshKey
        case certificate(CertificateRole)
        case pkcs12
        case serviceAccountKey
        var id: Int { hashValue }
    }

    init(editing connection: DatabaseConnection? = nil, onSaved: @escaping (UUID) -> Void) {
        _viewModel = State(wrappedValue: ConnectionFormViewModel(editing: connection))
        self.onSaved = onSaved
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

    private var showFileError: Binding<Bool> {
        Binding(
            get: { viewModel.fileError != nil },
            set: { if !$0 { viewModel.dismissFileError() } }
        )
    }

    private var showSSHKeyFileError: Binding<Bool> {
        Binding(
            get: { viewModel.sshKeyFileError != nil },
            set: { if !$0 { viewModel.dismissSSHKeyFileError() } }
        )
    }

    private var showServiceAccountKeyFileError: Binding<Bool> {
        Binding(
            get: { viewModel.iam.serviceAccountKeyFileError != nil },
            set: { if !$0 { viewModel.dismissServiceAccountKeyFileError() } }
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

                if viewModel.type == .mongodb {
                    mongoSection(viewModel: viewModel)
                }

                if !viewModel.isFileBased {
                    Section {
                        if viewModel.type == .oracle {
                            Picker(String(localized: "SSL Mode"), selection: $viewModel.oracleSSLMode) {
                                Text(String(localized: "Disabled")).tag(SSLModeChoice.disable)
                                Text(String(localized: "Preferred")).tag(SSLModeChoice.preferred)
                                Text(String(localized: "Required")).tag(SSLModeChoice.require)
                                if viewModel.offersOracleVerifyCa {
                                    Text(String(localized: "Verify CA")).tag(SSLModeChoice.verifyCa)
                                }
                                Text(String(localized: "Verify Identity")).tag(SSLModeChoice.verifyFull)
                            }
                        } else if viewModel.type == .mssql {
                            // No verify modes: this form collects no CA file for FreeTDS, so the iOS driver checks no certificate.
                            Picker(String(localized: "SSL Mode"), selection: $viewModel.mssqlSSLMode) {
                                Text(String(localized: "Disabled")).tag(SSLModeChoice.disable)
                                Text(String(localized: "Preferred")).tag(SSLModeChoice.preferred)
                                Text(String(localized: "Required")).tag(SSLModeChoice.require)
                            }
                        }
                    } footer: {
                        if let note = viewModel.oracleSSLModeNote {
                            Text(note)
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

                if !MacOnlyConnection.isMacOnly(type: viewModel.type) {
                    testSection
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .interactiveDismissDisabled(viewModel.hasChanges)
            .holdsScene(withUnsavedChanges: viewModel.hasChanges)
            .task {
                viewModel.loadCertificateSummaries()
                await viewModel.loadStoredCredentials(secureStore: appState.secureStore)
            }
            .task(id: viewModel.iam.identityCenter.request) {
                await viewModel.runIdentityCenterRequest()
            }
            .navigationTitle(viewModel.isEditing ? String(localized: "Edit Connection") : String(localized: "New Connection"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    DiscardChangesCancelButton(hasChanges: viewModel.hasChanges) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    ConfirmButton(title: "Save", action: handleSave)
                        .disabled(!viewModel.canSave || viewModel.isSaving)
                        .confirmationDialog(
                            String(localized: "Reconnect and Roll Back?"),
                            isPresented: confirmingReconnect,
                            titleVisibility: .visible,
                            presenting: reconnectingConnectionName
                        ) { _ in
                            Button(String(localized: "Save and Reconnect"), role: .destructive) { save() }
                            Button(String(localized: "Cancel"), role: .cancel) {}
                        } message: { name in
                            Text(OpenTransactionWarning.reconnectingOnSave(connectionName: name))
                        }
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
                case .serviceAccountKey: viewModel.importServiceAccountKeyFile(result)
                case nil: break
                }
            }
            .navigationDestination(item: $pushedJumpHostId) { hopId in
                JumpHostEditorView(viewModel: viewModel, hopId: hopId)
            }
            .connectionPrompts(viewModel.prompts)
            .onDisappear { viewModel.prompts.cancelAll() }
            .sheet(item: $pasteTarget) { role in
                CertificatePasteSheet(viewModel: viewModel, role: role)
            }
            .sheet(isPresented: $pastingServiceAccountKey) {
                ServiceAccountKeyPasteSheet(viewModel: viewModel)
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
            .alert("Database File", isPresented: showFileError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.fileError ?? "")
            }
            .alert("Private Key", isPresented: showSSHKeyFileError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.sshKeyFileError ?? "")
            }
            .alert("Service Account Key", isPresented: showServiceAccountKeyFileError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.iam.serviceAccountKeyFileError ?? "")
            }
            .libraryWriteFailureAlert(
                viewModel.saveFailure,
                onDismiss: viewModel.dismissSaveFailure,
                closeForm: { dismiss() }
            )
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

            if DatabaseType.mobileSupportedTypes.contains(viewModel.type) {
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
            } else {
                LabeledContent("Database Type", value: viewModel.type.mobileDisplayName)
            }
        }
    }

    @ViewBuilder
    private func organizationSection(viewModel: ConnectionFormViewModel) -> some View {
        @Bindable var viewModel = viewModel
        let graph = LibraryGroupGraph(groups: appState.groups)
        Section("Organization") {
            SymbolPickerRow(selection: $viewModel.iconName, subject: .connection(viewModel.type))

            Picker("Group", selection: $viewModel.groupId) {
                Text("None").tag(UUID?.none)
                ForEach(graph.flattened(), id: \.id) { entry in
                    Text(verbatim: graph.pathNames(to: entry.id).joined(separator: " / "))
                        .tag(Optional(entry.id))
                }
            }
            .pickerStyle(.menu)

            Picker("Tag", selection: $viewModel.tagId) {
                Text("None").tag(UUID?.none)
                ForEach(appState.tags) { tag in
                    Text(verbatim: tag.name)
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

            Picker(
                String(localized: "Network Encryption"),
                selection: $viewModel.oracleNetworkEncryption
            ) {
                Text(String(localized: "Accepted")).tag(OracleConnectionOptions.NetworkEncryption.accepted)
                Text(String(localized: "Rejected")).tag(OracleConnectionOptions.NetworkEncryption.rejected)
                Text(String(localized: "Requested")).tag(OracleConnectionOptions.NetworkEncryption.requested)
                Text(String(localized: "Required")).tag(OracleConnectionOptions.NetworkEncryption.required)
            }
        }
    }

    private func mongoSection(viewModel: ConnectionFormViewModel) -> some View {
        @Bindable var viewModel = viewModel
        return Section("MongoDB") {
            TextField("Auth Database", text: $viewModel.mongoAuthSource)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
            Picker("Auth Mechanism", selection: $viewModel.mongoAuthMechanism) {
                Text("Default").tag("")
                Text(verbatim: "SCRAM-SHA-1").tag("SCRAM-SHA-1")
                Text(verbatim: "SCRAM-SHA-256").tag("SCRAM-SHA-256")
                Text(verbatim: "X.509").tag("MONGODB-X509")
                Text("AWS IAM").tag("MONGODB-AWS")
            }
            TextField("Replica Set", text: $viewModel.mongoReplicaSet)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
            Toggle("Use SRV Record", isOn: $viewModel.mongoUsesSRV)
        }
    }

    @ViewBuilder
    private func serverSection(viewModel: ConnectionFormViewModel) -> some View {
        @Bindable var viewModel = viewModel
        Section {
            if viewModel.type == .mongodb {
                TextField("Hosts", text: $viewModel.mongoHosts)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } else {
                TextField("Host", text: $viewModel.host)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                TextField("Port", text: $viewModel.port)
                    .keyboardType(.numberPad)
            }
            TextField("Username", text: $viewModel.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
            if !viewModel.signsInWithIAM {
                SecureField("Password", text: $viewModel.password)
            }
        } header: {
            Text("Server")
        } footer: {
            if viewModel.type == .redis {
                Text("Username is for Redis 6 and later ACL users. Leave it empty for password-only servers.")
            } else if viewModel.type == .mongodb {
                if let issue = viewModel.mongoHostsIssue {
                    Text(issue)
                } else {
                    Text("Separate the servers of a replica set with commas.")
                }
            }
        }
        if viewModel.offersIAM {
            ConnectionAuthenticationSection(
                viewModel: viewModel,
                onChooseKeyFile: { present(.serviceAccountKey) },
                onPasteKey: { pastingServiceAccountKey = true }
            )
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
            Section {
                Group {
                    TextField("SSH Host", text: $viewModel.sshHost)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("SSH Port", text: $viewModel.sshPort, prompt: Text(verbatim: "22"))
                        .keyboardType(.numberPad)
                    TextField("SSH Username", text: $viewModel.sshUsername)
                        .textInputAutocapitalization(.never)

                    Picker("Auth Method", selection: $viewModel.sshAuthMethod) {
                        Text("Password").tag(SSHConfiguration.SSHAuthMethod.password)
                        Text("Private Key").tag(SSHConfiguration.SSHAuthMethod.privateKey)
                        Text("Keyboard Interactive").tag(SSHConfiguration.SSHAuthMethod.keyboardInteractive)
                    }
                }
                .disabled(viewModel.sshFollowsMacProfile)
            } header: {
                Text("SSH Server")
            } footer: {
                if viewModel.sshFollowsMacProfile {
                    Text("This tunnel follows an SSH profile on your Mac. Change the server there.")
                } else if let note = viewModel.sshAuthMethodNote {
                    Text(note)
                }
            }

            if viewModel.sshAuthMethod == .password {
                Section("SSH Password") {
                    if viewModel.sshFollowsMacProfile, viewModel.hasSSHProfilePassword {
                        Text("Signs in with the SSH profile's password from iCloud Keychain.")
                            .foregroundStyle(.secondary)
                    } else {
                        SecureField("Password", text: $viewModel.sshPassword)
                    }
                }
            } else if viewModel.sshAuthMethod == .privateKey {
                privateKeySection(viewModel: viewModel)
            } else if viewModel.sshAuthMethod == .keyboardInteractive {
                Section {
                    SecureField("Password (optional)", text: $viewModel.sshPassword)
                } header: {
                    Text("SSH Password")
                } footer: {
                    Text("Answers the server's password prompt. TablePro asks you for anything else when you connect.")
                }
            }

            if viewModel.offersTwoFactor {
                twoFactorSection(viewModel: viewModel)
            }

            JumpHostsSection(viewModel: viewModel, isEditable: !viewModel.sshFollowsMacProfile) { pushedJumpHostId = $0 }

            if let route = viewModel.macRoute {
                MacRouteSection(viewModel: viewModel, route: route)
            }
        }
    }

    @ViewBuilder
    private func twoFactorSection(viewModel: ConnectionFormViewModel) -> some View {
        @Bindable var viewModel = viewModel
        Section {
            Picker("TOTP", selection: $viewModel.totpMode) {
                ForEach(TOTPMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            if viewModel.totpMode == .autoGenerate {
                SecureField("TOTP Secret", text: $viewModel.totpSecret)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Picker("Algorithm", selection: $viewModel.totpAlgorithm) {
                    ForEach(TOTPAlgorithm.allCases) { algorithm in
                        Text(verbatim: algorithm.rawValue).tag(algorithm)
                    }
                }
                Picker("Digits", selection: $viewModel.totpDigits) {
                    Text(verbatim: "6").tag(6)
                    Text(verbatim: "8").tag(8)
                }
                Picker("Period", selection: $viewModel.totpPeriod) {
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                }
            }
        } header: {
            Text("Two-Factor Authentication")
        } footer: {
            if viewModel.totpMode == .autoGenerate {
                Text("The Base32 secret from your authenticator setup. TablePro enters the code when the server asks.")
            } else {
                Text("If the SSH server asks for a verification code, TablePro asks you for it when you connect.")
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
        await viewModel.testConnection()
        if let result = viewModel.testResult {
            if result.success { hapticSuccess.toggle() } else { hapticError.toggle() }
        }
    }

    private var confirmingReconnect: Binding<Bool> {
        Binding(
            get: { reconnectingConnectionName != nil },
            set: { if !$0 { reconnectingConnectionName = nil } }
        )
    }

    // A save that redials drops the session, and the server rolls back the transaction it held.
    private func handleSave() {
        let current = appState.connections.first { $0.id == viewModel.connectionId }
        if let current, viewModel.redialsAfterSave(over: current),
           appState.sessionTransactions.hold(for: current.id) != nil {
            reconnectingConnectionName = current.name.isEmpty ? current.host : current.name
            return
        }
        save()
    }

    private func save() {
        let reconnects = viewModel.reconnectsAfterSave
        Task {
            guard let savedId = await viewModel.save(appState: appState, secureStore: appState.secureStore) else {
                return
            }
            if reconnects {
                coordinatorStore.invalidate(savedId)
            }
            onSaved(savedId)
        }
    }

    // MARK: - Helpers

    private func contentTypes(for picker: ActiveFilePicker?) -> [UTType] {
        switch picker {
        case .sqliteDatabase: return sqliteContentTypes
        case .duckdbDatabase: return duckDBContentTypes
        case .certificate: return certificateContentTypes
        case .pkcs12: return pkcs12ContentTypes
        case .serviceAccountKey: return [.json]
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
