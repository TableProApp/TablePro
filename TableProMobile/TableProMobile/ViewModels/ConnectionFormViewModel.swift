import Foundation
import os
import TableProDatabase
import TableProModels
import TableProOracleCore

@MainActor
@Observable
final class ConnectionFormViewModel {
    enum KeyInputMode: String, CaseIterable {
        case file = "Import File"
        case paste = "Paste Key"

        var displayName: LocalizedStringResource {
            switch self {
            case .file: LocalizedStringResource("Import File")
            case .paste: LocalizedStringResource("Paste Key")
            }
        }
    }

    struct TestResult: Sendable {
        let success: Bool
        let message: String
        let recovery: String?
        var suggestedOracleMode: OracleConnectionOptions.IdentifierMode?
    }

    nonisolated enum PendingDatabaseFile: Equatable, Sendable {
        case documentsFile
        case newDocumentsFile(URL)
        case bookmarked(Data)
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionFormViewModel")

    // Form fields
    var name = ""
    var type: DatabaseType = .mysql {
        didSet { onTypeChange(from: oldValue) }
    }
    var host = "127.0.0.1"
    var port = "3306"
    var username = ""
    var password = ""
    var database = ""
    var sslEnabled = false
    var sslMode: SSLConfiguration.SSLMode = .disable
    var mssqlSSLMode: SSLConfiguration.SSLMode = .disable
    var oracleSSLMode: SSLConfiguration.SSLMode = .disable

    // Client certificates
    var certificateSummaries: [CertificateRole: String] = [:]
    var certificateError: String?
    var pastedCertificate = ""
    var pkcs12Password = ""
    @ObservationIgnored var pendingCertificates: [CertificateRole: String] = [:]
    @ObservationIgnored var removedCertificates: Set<CertificateRole> = []
    @ObservationIgnored var pendingPKCS12: Data?
    @ObservationIgnored let certificateStore: any CertificateMaterialStoring = CertificateMaterialStore()
    var oracleConnectionType: OracleConnectionOptions.IdentifierMode = .service
    var oracleServiceName = ""
    var oracleSID = ""
    var oracleRole: OracleConnectionOptions.Role = .normal
    var oracleNetworkEncryption: OracleConnectionOptions.NetworkEncryption = .accepted

    // Organization
    var groupId: UUID?
    var tagId: UUID?
    var safeModeLevel: SafeModeLevel = .off

    // SSH
    var sshEnabled = false
    var sshHost = ""
    var sshPort = "22"
    var sshUsername = ""
    var sshPassword = ""
    var sshAuthMethod: SSHConfiguration.SSHAuthMethod = .password
    var sshKeyPath = ""
    var sshKeyContent = ""
    var sshKeyPassphrase = ""
    var sshKeyInputMode: KeyInputMode = .file

    // File picker output
    var selectedFileURL: URL?
    var newDatabaseName = ""
    var duckDBInMemory = false {
        didSet { onDuckDBInMemoryChange() }
    }
    private(set) var pendingFile: PendingDatabaseFile?
    private(set) var fileError: String?

    // Async state
    private(set) var isTesting = false
    private(set) var isSaving = false
    private(set) var testResult: TestResult?
    private(set) var credentialError: String?
    private(set) var saveFailure: LibraryWriteFailure?

    @ObservationIgnored let existingConnection: DatabaseConnection?
    @ObservationIgnored private(set) var openingEdits: ConnectionFormEdits?
    @ObservationIgnored private var createdFileURL: URL?
    @ObservationIgnored private let newConnectionId = UUID()
    @ObservationIgnored private var addedNewConnection = false
    private let localFiles: LocalDatabaseFileLocator
    private let fileCreator: any LocalDatabaseFileCreating
    private let bookmarkStore: FileBookmarkStore

    init(
        editing: DatabaseConnection? = nil,
        localFiles: LocalDatabaseFileLocator = .live,
        fileCreator: any LocalDatabaseFileCreating = DriverDatabaseFileCreator(),
        bookmarkStore: FileBookmarkStore = FileBookmarkStore()
    ) {
        self.existingConnection = editing
        self.localFiles = localFiles
        self.fileCreator = fileCreator
        self.bookmarkStore = bookmarkStore
        guard let conn = editing else {
            safeModeLevel = AppPreferences.defaultSafeMode
            return
        }
        name = conn.name
        type = conn.type
        host = conn.host
        port = String(conn.port)
        username = conn.username
        database = conn.database
        sslEnabled = conn.sslEnabled
        // Coerce verify modes to .require: FreeTDS doesn't honor per-connection cert verification
        // (MSSQLSSLMapping treats verify* as "require"). Matches what the driver actually does.
        let storedMode = conn.sslConfiguration?.mode ?? .disable
        mssqlSSLMode = (storedMode == .verifyCa || storedMode == .verifyFull) ? .require : storedMode
        oracleSSLMode = storedMode
        sslMode = conn.sslConfiguration?.mode ?? (conn.sslEnabled ? .require : .disable)
        oracleConnectionType = OracleConnectionOptions.identifierMode(from: conn.additionalFields)
        oracleServiceName = conn.additionalFields[OracleConnectionOptions.AdditionalFieldKey.serviceName] ?? ""
        oracleSID = conn.additionalFields[OracleConnectionOptions.AdditionalFieldKey.sid] ?? ""
        oracleRole = OracleConnectionOptions.role(from: conn.additionalFields)
        oracleNetworkEncryption = OracleConnectionOptions.networkEncryption(from: conn.additionalFields)
        sshEnabled = conn.sshEnabled
        groupId = conn.groupId
        tagId = conn.tagId
        safeModeLevel = conn.safeModeLevel
        if let ssh = conn.sshConfiguration {
            sshHost = ssh.host
            sshPort = String(ssh.port)
            sshUsername = ssh.username
            sshAuthMethod = ssh.authMethod
            sshKeyPath = ssh.privateKeyPath ?? ""
            sshKeyContent = ssh.privateKeyData ?? ""
            if let keyData = ssh.privateKeyData, !keyData.isEmpty {
                sshKeyInputMode = .paste
            }
        }
        hydrateDatabaseFile(from: conn)
        openingEdits = edits
    }

    private func hydrateDatabaseFile(from connection: DatabaseConnection) {
        guard connection.type == .sqlite || connection.type == .duckdb else { return }
        let location = localFiles.location(forStoredPath: connection.database)
        guard location != .inMemory else {
            if connection.type == .duckdb {
                duckDBInMemory = true
            }
            return
        }
        guard !connection.database.isEmpty else { return }
        selectedFileURL = location.fileURL ?? URL(fileURLWithPath: connection.database)
    }

    // MARK: - Computed

    var canSave: Bool {
        if type == .sqlite {
            return !database.isEmpty
        }
        if type == .duckdb {
            return duckDBInMemory || !database.isEmpty
        }
        return !host.isEmpty
    }

    var isFileBased: Bool {
        type == .sqlite || type == .duckdb
    }

    var isEditing: Bool { existingConnection != nil }

    var edits: ConnectionFormEdits {
        ConnectionFormEdits(
            name: name.isEmpty ? (selectedFileURL?.lastPathComponent ?? host) : name,
            type: type,
            host: host,
            port: Int(port) ?? 3_306,
            username: username,
            database: database,
            groupId: groupId,
            tagId: tagId,
            safeModeLevel: safeModeLevel,
            sslMode: effectiveSSLMode,
            sshTunnel: sshTunnel,
            oracle: oracleOptions
        )
    }

    private var effectiveSSLMode: SSLConfiguration.SSLMode? {
        switch type {
        case .sqlite, .duckdb: nil
        case .mssql: mssqlSSLMode
        case .oracle: oracleSSLMode
        default: sslMode
        }
    }

    private var sshTunnel: ConnectionFormEdits.SSHTunnel? {
        guard sshEnabled else { return nil }
        return ConnectionFormEdits.SSHTunnel(
            host: sshHost,
            port: Int(sshPort) ?? 22,
            username: sshUsername,
            authMethod: sshAuthMethod,
            privateKeyPath: sshKeyPath.isEmpty ? nil : sshKeyPath,
            privateKeyData: sshKeyContent.isEmpty ? nil : sshKeyContent
        )
    }

    private var oracleOptions: ConnectionFormEdits.OracleOptions? {
        guard type == .oracle else { return nil }
        return ConnectionFormEdits.OracleOptions(
            identifierMode: oracleConnectionType,
            serviceName: oracleServiceName,
            sid: oracleSID,
            role: oracleRole,
            networkEncryption: oracleNetworkEncryption
        )
    }

    // MARK: - Credential Hydration

    func loadStoredCredentials(secureStore: any SecureStore) async {
        guard let conn = existingConnection else { return }
        let connKey = "com.TablePro.password.\(conn.id.uuidString)"
        if let stored = try? secureStore.retrieve(forKey: connKey), !stored.isEmpty {
            password = stored
        }
        if let sshPwd = try? secureStore.retrieve(forKey: "com.TablePro.sshpassword.\(conn.id.uuidString)"), !sshPwd.isEmpty {
            sshPassword = sshPwd
        }
        if let passphrase = try? secureStore.retrieve(forKey: "com.TablePro.keypassphrase.\(conn.id.uuidString)"), !passphrase.isEmpty {
            sshKeyPassphrase = passphrase
        }
    }

    // MARK: - Type Change

    private func onTypeChange(from oldType: DatabaseType) {
        guard oldType != type else { return }
        updateDefaultPort()
        selectedFileURL = nil
        database = ""
        pendingFile = nil
        duckDBInMemory = false
    }

    private func onDuckDBInMemoryChange() {
        if duckDBInMemory {
            selectedFileURL = nil
            pendingFile = nil
            database = LocalDatabaseLocation.inMemoryPath
        } else if database == LocalDatabaseLocation.inMemoryPath {
            database = ""
        }
    }

    private func updateDefaultPort() {
        port = type.defaultPort
    }

    // MARK: - File Picker

    func handleSQLiteFilePicker(_ result: Result<[URL], Error>) {
        guard let url = pickedDatabaseURL(from: result) else { return }
        guard !localFiles.isInDocuments(url) else {
            adopt(url, pending: .documentsFile)
            return
        }
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        do {
            adopt(try localFiles.importCopy(of: url), pending: .documentsFile)
        } catch {
            fileError = error.localizedDescription
        }
    }

    func handleDuckDBFilePicker(_ result: Result<[URL], Error>) {
        guard let url = pickedDatabaseURL(from: result) else { return }
        guard !localFiles.isInDocuments(url) else {
            adopt(url, pending: .documentsFile)
            return
        }
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        do {
            adopt(url, pending: .bookmarked(try url.bookmarkData()))
        } catch {
            Self.logger.error("Bookmarking a DuckDB file failed: \(error.localizedDescription, privacy: .private)")
            fileError = LocalDatabaseFileError.accessDenied(fileName: url.lastPathComponent).localizedDescription
        }
    }

    private func pickedDatabaseURL(from result: Result<[URL], Error>) -> URL? {
        switch result {
        case .success(let urls):
            return urls.first
        case .failure(let error):
            fileError = error.localizedDescription
            return nil
        }
    }

    private func adopt(_ url: URL, pending: PendingDatabaseFile) {
        selectedFileURL = url
        database = url.path
        pendingFile = pending
        if name.isEmpty {
            name = url.deletingPathExtension().lastPathComponent
        }
    }

    func handleSSHKeyFilePicker(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
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

    func clearSelectedFile() {
        selectedFileURL = nil
        database = ""
        pendingFile = nil
    }

    func createNewDatabase() {
        let requestedName = newDatabaseName
        newDatabaseName = ""
        do {
            let url = try localFiles.newDatabaseFile(named: requestedName, type: type)
            adopt(url, pending: .newDocumentsFile(url))
        } catch {
            fileError = error.localizedDescription
        }
    }

    func dismissFileError() {
        fileError = nil
    }

    // MARK: - Test Connection

    func testConnection(appState: AppState, secureStore: any SecureStore) async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }

        let tempId = UUID()
        var testConn = buildConnection()
        testConn.id = tempId
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectionTest-\(tempId.uuidString)", isDirectory: true)

        storeTestSecrets(for: tempId, appState: appState, secureStore: secureStore)
        defer {
            deleteTestSecrets(for: tempId, appState: appState, secureStore: secureStore)
            removeScratchDirectory(scratchDirectory)
        }

        do {
            if let scratchPath = try await scratchDatabasePath(in: scratchDirectory) {
                testConn.database = scratchPath
            }
            _ = try await appState.connectionManager.connect(testConn)
            await appState.connectionManager.disconnect(tempId)
            testResult = TestResult(
                success: true,
                message: String(localized: "Connection successful"),
                recovery: nil
            )
        } catch {
            let context = ErrorContext(
                operation: "testConnection",
                databaseType: type,
                host: host,
                sshEnabled: sshEnabled
            )
            let classified = ErrorClassifier.classify(error, context: context)
            testResult = TestResult(
                success: false,
                message: classified.message,
                recovery: classified.recovery,
                suggestedOracleMode: classified.suggestedOracleMode
            )
        }
    }

    private func storeTestSecrets(for tempId: UUID, appState: AppState, secureStore: any SecureStore) {
        if !password.isEmpty {
            try? appState.connectionManager.storePassword(password, for: tempId)
        }
        if sshEnabled && !sshPassword.isEmpty {
            try? secureStore.store(sshPassword, forKey: "com.TablePro.sshpassword.\(tempId.uuidString)")
        }
        if sshEnabled && !sshKeyPassphrase.isEmpty {
            try? secureStore.store(sshKeyPassphrase, forKey: "com.TablePro.keypassphrase.\(tempId.uuidString)")
        }
        if sshEnabled && !sshKeyContent.isEmpty {
            try? secureStore.store(sshKeyContent, forKey: "com.TablePro.sshkeydata.\(tempId.uuidString)")
        }
        if let bookmark = bookmarkForTest {
            bookmarkStore.save(bookmark, for: tempId)
        }
    }

    private func deleteTestSecrets(for tempId: UUID, appState: AppState, secureStore: any SecureStore) {
        try? appState.connectionManager.deletePassword(for: tempId)
        try? secureStore.delete(forKey: "com.TablePro.sshpassword.\(tempId.uuidString)")
        try? secureStore.delete(forKey: "com.TablePro.keypassphrase.\(tempId.uuidString)")
        try? secureStore.delete(forKey: "com.TablePro.sshkeydata.\(tempId.uuidString)")
        bookmarkStore.delete(for: tempId)
    }

    private var bookmarkForTest: Data? {
        guard type == .duckdb, !duckDBInMemory else { return nil }
        switch pendingFile {
        case .bookmarked(let bookmark):
            return bookmark
        case .documentsFile, .newDocumentsFile:
            return nil
        case nil:
            return existingConnection.flatMap { bookmarkStore.bookmark(for: $0.id) }
        }
    }

    private func scratchDatabasePath(in scratchDirectory: URL) async throws -> String? {
        guard case .newDocumentsFile(let destination) = pendingFile else { return nil }
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let scratchFile = scratchDirectory.appendingPathComponent(destination.lastPathComponent)
        try await fileCreator.createDatabase(at: scratchFile, type: type)
        return scratchFile.path
    }

    private func removeScratchDirectory(_ directory: URL) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Self.logger.error("Removing a test database failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Save

    func save(appState: AppState, secureStore: any SecureStore) async -> UUID? {
        guard !isSaving else { return nil }
        isSaving = true
        defer { isSaving = false }

        guard await createPendingDatabaseFile() else { return nil }
        let draft = buildConnection()
        let outcome = writeToLibrary(draft, appState: appState)
        if let failure = LibraryWriteFailure(outcome, kind: .connection) {
            discardCreatedFile()
            saveFailure = failure
            return nil
        }
        createdFileURL = nil
        settleBookmark(for: draft.id)
        guard storeSecrets(for: draft.id, appState: appState, secureStore: secureStore) else { return nil }
        return draft.id
    }

    func applyingEdits(to current: DatabaseConnection) -> DatabaseConnection {
        edits.applied(to: current, changedSince: openingEdits)
    }

    func buildConnection() -> DatabaseConnection {
        edits.applied(to: existingConnection ?? DatabaseConnection(id: newConnectionId), changedSince: nil)
    }

    func dismissSaveFailure() {
        saveFailure = nil
    }

    private func writeToLibrary(_ draft: DatabaseConnection, appState: AppState) -> LibraryWriteOutcome {
        guard isEditing || addedNewConnection else {
            guard appState.addConnection(draft) else { return .refused }
            addedNewConnection = true
            return .applied
        }
        return appState.mutateConnection(draft.id) { $0 = applyingEdits(to: $0) }
    }

    private func createPendingDatabaseFile() async -> Bool {
        guard case .newDocumentsFile(let url) = pendingFile else { return true }
        do {
            try await fileCreator.createDatabase(at: url, type: type)
        } catch {
            fileError = error.localizedDescription
            return false
        }
        createdFileURL = url
        if pendingFile == .newDocumentsFile(url) {
            pendingFile = .documentsFile
        }
        return true
    }

    private func settleBookmark(for connectionId: UUID) {
        guard type == .duckdb else {
            if existingConnection?.type == .duckdb {
                bookmarkStore.delete(for: connectionId)
            }
            return
        }
        switch pendingFile {
        case .bookmarked(let bookmark):
            bookmarkStore.save(bookmark, for: connectionId)
        case .documentsFile, .newDocumentsFile:
            bookmarkStore.delete(for: connectionId)
        case nil:
            if duckDBInMemory {
                bookmarkStore.delete(for: connectionId)
            }
        }
    }

    private func discardCreatedFile() {
        guard let createdFileURL else { return }
        fileCreator.removeDatabase(at: createdFileURL)
        self.createdFileURL = nil
        if pendingFile == .documentsFile {
            pendingFile = .newDocumentsFile(createdFileURL)
        }
    }

    private func storeSecrets(for connectionId: UUID, appState: AppState, secureStore: any SecureStore) -> Bool {
        var storageFailed = false

        persistCertificates(for: connectionId)

        if !password.isEmpty {
            do {
                try appState.connectionManager.storePassword(password, for: connectionId)
            } catch {
                Self.logger.error("Failed to store password: \(error.localizedDescription, privacy: .public)")
                storageFailed = true
            }
        }

        if sshEnabled {
            if !sshPassword.isEmpty {
                do {
                    try secureStore.store(sshPassword, forKey: "com.TablePro.sshpassword.\(connectionId.uuidString)")
                } catch {
                    Self.logger.error("Failed to store SSH password: \(error.localizedDescription, privacy: .public)")
                    storageFailed = true
                }
            }
            if !sshKeyPassphrase.isEmpty {
                do {
                    try secureStore.store(sshKeyPassphrase, forKey: "com.TablePro.keypassphrase.\(connectionId.uuidString)")
                } catch {
                    Self.logger.error("Failed to store SSH key passphrase: \(error.localizedDescription, privacy: .public)")
                    storageFailed = true
                }
            }
            if !sshKeyContent.isEmpty {
                do {
                    try secureStore.store(sshKeyContent, forKey: "com.TablePro.sshkeydata.\(connectionId.uuidString)")
                } catch {
                    Self.logger.error("Failed to store SSH key data: \(error.localizedDescription, privacy: .public)")
                    storageFailed = true
                }
            }
        }

        guard !storageFailed else {
            credentialError = String(localized: "Some credentials could not be saved to the keychain. You may need to re-enter them later.")
            return false
        }
        return true
    }

    func dismissCredentialError() {
        credentialError = nil
    }
}
