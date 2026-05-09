//
//  ConnectionFormView.swift
//  TableProMobile
//

import SwiftUI
import TableProDatabase
import TableProModels
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

    var onSave: (DatabaseConnection) -> Void

    private let databaseTypes: [(DatabaseType, String)] = [
        (.mysql, "MySQL"),
        (.mariadb, "MariaDB"),
        (.postgresql, "PostgreSQL"),
        (.sqlite, "SQLite"),
        (.redis, "Redis"),
    ]

    enum ActiveFilePicker: Identifiable {
        case sqliteDatabase
        case sshKey
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
                } else {
                    serverSection(viewModel: viewModel)
                }

                if viewModel.type != .sqlite {
                    Section {
                        Toggle("SSL", isOn: $viewModel.sslEnabled)
                    }
                    sshSection(viewModel: viewModel)
                }

                testSection
            }
            .scrollDismissesKeyboard(.interactively)
            .task {
                await viewModel.loadStoredCredentials(secureStore: appState.secureStore)
            }
            .navigationTitle(viewModel.isEditing ? String(localized: "Edit Connection") : String(localized: "New Connection"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: handleSave)
                        .disabled(!viewModel.canSave)
                }
            }
            .fileImporter(
                isPresented: showFilePicker,
                allowedContentTypes: activeFilePicker == .sqliteDatabase ? sqliteContentTypes : [.data],
                allowsMultipleSelection: false
            ) { result in
                let picker = pendingFilePicker
                pendingFilePicker = nil
                switch picker {
                case .sqliteDatabase: viewModel.handleSQLiteFilePicker(result)
                case .sshKey: viewModel.handleSSHKeyFilePicker(result)
                case nil: break
                }
            }
            .alert("New Database", isPresented: $showNewDatabaseAlert) {
                TextField("Database name", text: $viewModel.newDatabaseName)
                Button("Create") { viewModel.createNewDatabase() }
                Button("Cancel", role: .cancel) { viewModel.newDatabaseName = "" }
            } message: {
                Text("Enter a name for the new SQLite database.")
            }
            .alert("Keychain Warning", isPresented: showCredentialError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.credentialError ?? "Failed to save credentials.")
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
                ForEach(databaseTypes, id: \.0.rawValue) { dbType, label in
                    Label {
                        Text(label)
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

    // MARK: - Server Section

    @ViewBuilder
    private func serverSection(viewModel: ConnectionFormViewModel) -> some View {
        @Bindable var viewModel = viewModel
        Section("Server") {
            TextField("Host", text: $viewModel.host)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            TextField("Port", text: $viewModel.port)
                .keyboardType(.numberPad)
            TextField("Username", text: $viewModel.username)
                .textInputAutocapitalization(.never)
            SecureField("Password", text: $viewModel.password)
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
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if viewModel.sshKeyInputMode == .file {
                Button {
                    pendingFilePicker = .sshKey
                    activeFilePicker = .sshKey
                } label: {
                    HStack {
                        Text(viewModel.sshKeyPath.isEmpty
                            ? "Select Private Key"
                            : URL(fileURLWithPath: viewModel.sshKeyPath).lastPathComponent)
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

    private var sqliteContentTypes: [UTType] {
        [UTType.database, UTType(filenameExtension: "sqlite3") ?? .data, .data]
    }
}
