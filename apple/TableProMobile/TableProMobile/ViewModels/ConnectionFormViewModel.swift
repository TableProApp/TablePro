import Foundation
import os
import TableProConnectionLibrary
import TableProDatabase
import TableProModels
import TableProOracleCore
import TableProSSHTransport

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
    var pendingCertificates: [CertificateRole: String] = [:]
    var removedCertificates: Set<CertificateRole> = []
    var storedCertificateRoles: Set<CertificateRole> = []
    @ObservationIgnored var pendingPKCS12: Data?
    @ObservationIgnored let certificateStore: any CertificateMaterialStoring
    var oracleConnectionType: OracleConnectionOptions.IdentifierMode = .service
    var oracleServiceName = ""
    var oracleSID = ""
    var oracleRole: OracleConnectionOptions.Role = .normal
    var oracleNetworkEncryption: OracleConnectionOptions.NetworkEncryption = .accepted

    // Organization
    var groupId: UUID?
    var tagId: UUID?
    var iconName: String?
    var safeModeLevel: SafeModeLevel = .off

    // SSH
    var sshEnabled = false
    var sshHost = ""
    var sshPort = ""
    var sshUsername = ""
    var sshPassword = ""
    var sshAuthMethod: SSHConfiguration.SSHAuthMethod = .password
    var sshKeyPath = ""
    var sshKeyContent = ""
    var sshKeyPassphrase = ""
    var sshKeyInputMode: KeyInputMode = .file

    // Two-factor sign-in, in the Mac's settings
    var totpMode: TOTPMode = .none
    var totpSecret = ""
    var totpAlgorithm: TOTPAlgorithm = .sha1
    var totpDigits = 6
    var totpPeriod = 30

    // Jump hosts
    var jumpHosts: [JumpHostDraft] = []
    // Hops only the Mac's ~/.ssh/config names, from the route it published. Host fields are the Mac's.
    var routeHops: [JumpHostDraft] = []
    var jumpHostKeyFileError: String?
    private(set) var jumpHostCredentialsUnreadable = false

    // File picker output
    var selectedFileURL: URL?
    var newDatabaseName = ""
    var duckDBInMemory = false {
        didSet { onDuckDBInMemoryChange() }
    }
    private(set) var pendingFile: PendingDatabaseFile?
    private(set) var fileError: String?
    private(set) var sshKeyFileError: String?

    // Async state
    private(set) var isTesting = false

    /// Test Connection asks its own questions, shown from the form sheet that started it.
    let prompts = ConnectionPromptQueue()
    private(set) var isSaving = false
    private(set) var testResult: TestResult?
    private(set) var credentialError: String?
    private(set) var saveFailure: LibraryWriteFailure?

    @ObservationIgnored let existingConnection: DatabaseConnection?
    @ObservationIgnored let connectionId: UUID
    @ObservationIgnored private var createdFileURL: URL?
    @ObservationIgnored private var addedNewConnection = false
    @ObservationIgnored private var loadedStoredCredentials = false
    @ObservationIgnored private var sshProfileSecrets: [String: String] = [:]
    private(set) var baseline: ConnectionFormSnapshot?
    private(set) var storedSecrets = ConnectionFormSecrets()
    private let localFiles: LocalDatabaseFileLocator
    private let fileCreator: any LocalDatabaseFileCreating
    private let bookmarkStore: FileBookmarkStore

    init(
        editing: DatabaseConnection? = nil,
        localFiles: LocalDatabaseFileLocator = .live,
        fileCreator: any LocalDatabaseFileCreating = DriverDatabaseFileCreator(),
        bookmarkStore: FileBookmarkStore = FileBookmarkStore(),
        certificateStore: any CertificateMaterialStoring = CertificateMaterialStore()
    ) {
        self.existingConnection = editing
        self.connectionId = editing?.id ?? UUID()
        self.localFiles = localFiles
        self.fileCreator = fileCreator
        self.bookmarkStore = bookmarkStore
        self.certificateStore = certificateStore
        defer { baseline = snapshot }
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
        // Coerce verify modes to .require: the iOS driver encrypts without checking the certificate
        // (DriverSSLConfiguration maps verify* to "require"). Matches what the driver actually does.
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
        iconName = conn.iconName
        safeModeLevel = conn.safeModeLevel
        if let ssh = conn.sshConfiguration {
            sshHost = ssh.host
            sshPort = ssh.port.map(String.init) ?? ""
            sshUsername = ssh.username
            sshAuthMethod = ssh.authMethod.onDevice
            sshKeyPath = ssh.privateKeyPath ?? ""
            if sshAuthMethod == .privateKey, sshKeyPath.isEmpty {
                sshKeyInputMode = .paste
            }
            jumpHosts = ssh.jumpHosts.map(JumpHostDraft.init(hop:))
            totpMode = ssh.totpMode.flatMap(TOTPMode.init(rawValue:)) ?? .none
            totpAlgorithm = ssh.totpAlgorithm.flatMap(TOTPAlgorithm.init(rawValue:)) ?? .sha1
            totpDigits = ssh.totpDigits ?? 6
            totpPeriod = ssh.totpPeriod ?? 30
            let typedHopIds = Set(ssh.jumpHosts.map(\.id))
            routeHops = (conn.sshRoute?.hops ?? [])
                .filter { !typedHopIds.contains($0.id) }
                .map(JumpHostDraft.init(routeHop:))
        }
        hydrateDatabaseFile(from: conn)
    }

    private func hydrateDatabaseFile(from connection: DatabaseConnection) {
        guard connection.type.isLocalFile else { return }
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
        return !host.isEmpty && !hasJumpHostWithoutHost
    }

    var isFileBased: Bool {
        type.isLocalFile
    }

    var isEditing: Bool { existingConnection != nil }

    var pastedPrivateKey: String? {
        guard sshEnabled, sshAuthMethod.onDevice == .privateKey, sshKeyInputMode == .paste,
              !sshKeyContent.isEmpty else { return nil }
        return sshKeyContent
    }

    // A Mac SSH profile owns its two-factor settings, as it owns the server.
    var offersTwoFactor: Bool {
        sshAuthMethod != .none && !sshFollowsMacProfile
    }

    var sshAuthMethodNote: String? {
        switch sshAuthMethod {
        case .privateKey where existingConnection?.sshConfiguration?.authMethod == .sshAgent:
            String(localized: "Set to SSH Agent on the Mac. iPhone and iPad sign in with a private key.")
        default:
            nil
        }
    }

    var edits: ConnectionFormEdits {
        ConnectionFormEdits(
            name: name.isEmpty ? (selectedFileURL?.lastPathComponent ?? host) : name,
            type: type,
            host: host,
            port: Int(port) ?? Int(type.defaultPort) ?? 0,
            username: username,
            database: database,
            groupId: groupId,
            tagId: tagId,
            iconName: LibrarySymbolCatalog.normalizedName(iconName),
            safeModeLevel: safeModeLevel,
            sslMode: effectiveSSLMode,
            sshTunnel: sshTunnel,
            oracle: oracleOptions
        )
    }

    var offersOracleVerifyCa: Bool {
        existingConnection?.sslConfiguration?.mode == .verifyCa
    }

    var oracleSSLModeNote: String? {
        guard type == .oracle, oracleSSLMode == .verifyCa else { return nil }
        return DriverSSLConfiguration.oracleVerifyCaUnavailableMessage
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
            port: Int(sshPort),
            username: sshUsername,
            authMethod: sshAuthMethodToStore,
            privateKeyPath: sshKeyPath.isEmpty ? nil : sshKeyPath,
            jumpHosts: jumpHosts.map(\.edit),
            totp: ConnectionFormEdits.TOTPSettings(
                mode: totpMode.rawValue,
                algorithm: totpAlgorithm.rawValue,
                digits: totpDigits,
                period: totpPeriod
            )
        )
    }

    // The picker shows how this device signs in. Left as it opened, the method goes back as the Mac
    // stored it, which matters when a switched-off tunnel is turned on and every field is written.
    private var sshAuthMethodToStore: SSHConfiguration.SSHAuthMethod {
        guard let stored = existingConnection?.sshConfiguration?.authMethod, stored.onDevice == sshAuthMethod else {
            return sshAuthMethod
        }
        return stored
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

    // The form's `.task` runs again whenever a pushed screen pops, and a second load would overwrite edits.
    func loadStoredCredentials(secureStore: any SecureStore) async {
        guard let conn = existingConnection, !loadedStoredCredentials else { return }
        loadedStoredCredentials = true
        if let stored = Self.storedSecret(.password, for: conn.id, in: secureStore) {
            password = stored
            storedSecrets.password = stored
        }
        if let sshPwd = Self.storedSecret(.sshPassword, for: conn.id, in: secureStore) {
            sshPassword = sshPwd
            storedSecrets.sshPassword = sshPwd
        }
        if let passphrase = Self.storedSecret(.keyPassphrase, for: conn.id, in: secureStore) {
            sshKeyPassphrase = passphrase
            storedSecrets.sshKeyPassphrase = passphrase
        }
        if let privateKey = Self.storedSecret(.sshPrivateKey, for: conn.id, in: secureStore) {
            sshKeyContent = privateKey
            storedSecrets.privateKey = privateKey
            sshKeyInputMode = .paste
        }
        if let secret = Self.storedSecret(.totpSecret, for: conn.id, in: secureStore) {
            totpSecret = secret
            storedSecrets.totpSecret = secret
        }
        loadJumpHostCredentials(for: conn, in: secureStore)
        if let profileId = conn.sshProfileId {
            for kind in SSHProfileSecretKind.allCases {
                let account = kind.account(for: profileId)
                guard let value = try? secureStore.retrieve(forKey: account), !value.isEmpty else { continue }
                sshProfileSecrets[account] = value
            }
        }
        baseline?.secrets = snapshot.secrets
    }

    var hasSSHProfilePassword: Bool {
        guard let profileId = existingConnection?.sshProfileId else { return false }
        return sshProfileSecrets[SSHProfileSecretKind.password.account(for: profileId)] != nil
    }

    private func loadJumpHostCredentials(for connection: DatabaseConnection, in secureStore: any SecureStore) {
        guard connection.sshConfiguration?.jumpHosts.isEmpty == false || !routeHops.isEmpty else { return }
        let loaded: [UUID: JumpHostCredential]
        do {
            loaded = try JumpHostCredentialStore.load(for: connection.id, in: secureStore)
        } catch {
            Self.logger.error("Failed to read jump host keys: \(error.localizedDescription, privacy: .private)")
            jumpHostCredentialsUnreadable = true
            credentialError = Self.jumpHostKeysUnreadableMessage
            return
        }
        let shown = jumpHostIdsShown
        storedSecrets.jumpHostCredentials = loaded.filter { shown.contains($0.key) }
        for index in jumpHosts.indices {
            guard let credential = loaded[jumpHosts[index].id] else { continue }
            jumpHosts[index].adopt(credential)
        }
        for index in routeHops.indices {
            guard let credential = loaded[routeHops[index].id] else { continue }
            routeHops[index].adopt(credential)
        }
    }

    private static func storedSecret(
        _ kind: ConnectionSecretKind,
        for connectionId: UUID,
        in secureStore: any SecureStore
    ) -> String? {
        guard let value = try? secureStore.retrieve(forKey: kind.account(for: connectionId)),
              !value.isEmpty else { return nil }
        return value
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
        let url: URL
        switch result {
        case .success(let urls):
            guard let first = urls.first else { return }
            url = first
        case .failure(let error):
            sshKeyFileError = error.localizedDescription
            return
        }
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }

        if let content = try? String(contentsOf: url, encoding: .utf8) {
            sshKeyContent = content
            sshKeyInputMode = .paste
            return
        }
        guard !localFiles.isInDocuments(url) else {
            sshKeyPath = url.path
            return
        }
        do {
            sshKeyPath = try localFiles.importCopy(of: url).path
        } catch {
            sshKeyFileError = error.localizedDescription
        }
    }

    func dismissSSHKeyFileError() {
        sshKeyFileError = nil
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

    func testSecrets(for connectionId: UUID) -> [String: String] {
        var secrets: [String: String] = [:]
        if !password.isEmpty {
            secrets[ConnectionSecretKind.password.account(for: connectionId)] = password
        }
        guard sshEnabled else { return secrets }
        if !sshPassword.isEmpty {
            secrets[ConnectionSecretKind.sshPassword.account(for: connectionId)] = sshPassword
        }
        if !sshKeyPassphrase.isEmpty {
            secrets[ConnectionSecretKind.keyPassphrase.account(for: connectionId)] = sshKeyPassphrase
        }
        if let pastedPrivateKey {
            secrets[ConnectionSecretKind.sshPrivateKey.account(for: connectionId)] = pastedPrivateKey
        }
        if !totpSecret.isEmpty {
            secrets[ConnectionSecretKind.totpSecret.account(for: connectionId)] = totpSecret
        }
        secrets.merge(sshProfileSecrets) { own, _ in own }
        let hopCredentials = jumpHostCredentials
        guard !hopCredentials.isEmpty else { return secrets }
        do {
            secrets[ConnectionSecretKind.jumpHostKeys.account(for: connectionId)] =
                try JumpHostCredentialStore.encode(hopCredentials)
        } catch {
            Self.logger.error("Failed to encode jump host keys: \(error.localizedDescription, privacy: .private)")
        }
        return secrets
    }

    func testConnection() async {
        isTesting = true
        testResult = nil
        defer {
            isTesting = false
            prompts.cancelAll()
        }

        let tempId = UUID()
        var testConn = buildConnection()
        testConn.id = tempId
        let scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectionTest-\(tempId.uuidString)", isDirectory: true)

        let secrets = EphemeralSecureStore(testSecrets(for: tempId))
        let manager = ConnectionManager(
            driverFactory: IOSDriverFactory(bookmarkStore: bookmarkStore, localFiles: localFiles),
            secureStore: secrets,
            sshProvider: IOSSSHProvider(secureStore: secrets, container: localFiles.container)
        )
        if let bookmark = bookmarkForTest {
            bookmarkStore.save(bookmark, for: tempId)
        }
        defer {
            bookmarkStore.delete(for: tempId)
            removeScratchDirectory(scratchDirectory)
        }

        do {
            if let scratchPath = try await scratchDatabasePath(in: scratchDirectory) {
                testConn.database = scratchPath
            }
            _ = try await manager.connect(testConn, prompter: prompts)
            await manager.disconnect(tempId)
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
        settleBookmark()
        let storedEverySecret = storeSecrets(appState: appState, secureStore: secureStore)
        advanceBaselineToSavedState()
        guard storedEverySecret else { return nil }
        return connectionId
    }

    func applyingEdits(to current: DatabaseConnection) -> DatabaseConnection {
        edits.applied(to: current, changedSince: openingEdits)
    }

    func buildConnection() -> DatabaseConnection {
        edits.applied(to: existingConnection ?? DatabaseConnection(id: connectionId), changedSince: nil)
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

    private func settleBookmark() {
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

    private func storeSecrets(appState: AppState, secureStore: any SecureStore) -> Bool {
        let writes = secretWrites
        var storageFailed = !persistCertificates(for: connectionId)

        if let changed = writes.password {
            do {
                try appState.connectionManager.storePassword(changed, for: connectionId)
                storedSecrets.password = changed
            } catch {
                Self.logger.error("Failed to store password: \(error.localizedDescription, privacy: .public)")
                storageFailed = true
            }
        }

        if let changed = writes.sshPassword {
            do {
                try secureStore.store(changed, forKey: ConnectionSecretKind.sshPassword.account(for: connectionId))
                storedSecrets.sshPassword = changed
            } catch {
                Self.logger.error("Failed to store SSH password: \(error.localizedDescription, privacy: .public)")
                storageFailed = true
            }
        }
        if let changed = writes.sshKeyPassphrase {
            do {
                try secureStore.store(changed, forKey: ConnectionSecretKind.keyPassphrase.account(for: connectionId))
                storedSecrets.sshKeyPassphrase = changed
            } catch {
                Self.logger.error("Failed to store SSH key passphrase: \(error.localizedDescription, privacy: .public)")
                storageFailed = true
            }
        }
        if let changed = writes.totpSecret {
            do {
                try secureStore.store(changed, forKey: ConnectionSecretKind.totpSecret.account(for: connectionId))
                storedSecrets.totpSecret = changed
            } catch {
                Self.logger.error("Failed to store TOTP secret: \(error.localizedDescription, privacy: .public)")
                storageFailed = true
            }
        }

        do {
            try persistPrivateKey(secureStore: secureStore)
        } catch {
            Self.logger.error("Failed to store SSH private key: \(error.localizedDescription, privacy: .public)")
            storageFailed = true
        }

        do {
            try persistJumpHostCredentials(secureStore: secureStore)
        } catch {
            Self.logger.error("Failed to store jump host keys: \(error.localizedDescription, privacy: .private)")
            storageFailed = true
        }

        guard !storageFailed else {
            credentialError = String(localized: "Some credentials could not be saved to the keychain. You may need to re-enter them later.")
            return false
        }
        return true
    }

    private func advanceBaselineToSavedState() {
        baseline = ConnectionFormSnapshot(
            edits: edits,
            secrets: storedSecrets,
            stagedCertificates: [:],
            removedStoredCertificates: []
        )
    }

    func persistPrivateKey(secureStore: any SecureStore) throws {
        let key = pastedPrivateKey
        guard key != storedSecrets.privateKey else { return }
        let account = ConnectionSecretKind.sshPrivateKey.account(for: connectionId)
        if let key {
            try secureStore.store(key, forKey: account)
        } else {
            try secureStore.delete(forKey: account)
        }
        storedSecrets.privateKey = key
    }

    // The item is synced to every device, which may have changed it while the form was open, so it
    // is re-read and only the entries this form changed are written. An item that could not be read
    // when the form opened is never written; a failed re-read throws, and the next Save tries again.
    func persistJumpHostCredentials(secureStore: any SecureStore) throws {
        guard !jumpHostCredentialsUnreadable else { return }
        let credentials = jumpHostCredentials
        let loaded = storedSecrets.jumpHostCredentials
        guard credentials != loaded else { return }
        var stored = try JumpHostCredentialStore.load(for: connectionId, in: secureStore)
        let kept = Set(jumpHosts.map(\.id) + routeHops.map(\.id))
        for hopId in jumpHostIdsShown where !kept.contains(hopId) || credentials[hopId] != loaded[hopId] {
            stored[hopId] = credentials[hopId]
        }
        try JumpHostCredentialStore.save(sshEnabled ? stored : [:], for: connectionId, in: secureStore)
        storedSecrets.jumpHostCredentials = credentials
    }

    func dismissCredentialError() {
        credentialError = nil
    }
}
