import Foundation
import os
import TableProDatabase
import TableProModels

@MainActor
@Observable
final class ConnectionFormViewModel {
    enum KeyInputMode: String, CaseIterable {
        case file = "Import File"
        case paste = "Paste Key"
    }

    struct TestResult: Sendable {
        let success: Bool
        let message: String
        let recovery: String?
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

    // Async state
    private(set) var isTesting = false
    private(set) var testResult: TestResult?
    private(set) var credentialError: String?

    @ObservationIgnored let existingConnection: DatabaseConnection?

    init(editing: DatabaseConnection? = nil) {
        self.existingConnection = editing
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
        if conn.type == .sqlite {
            selectedFileURL = URL(fileURLWithPath: conn.database)
        }
    }

    // MARK: - Computed

    var canSave: Bool {
        if type == .sqlite {
            return !database.isEmpty
        }
        return !host.isEmpty
    }

    var isEditing: Bool { existingConnection != nil }

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
    }

    private func updateDefaultPort() {
        port = type.defaultPort
    }

    // MARK: - File Picker

    func handleSQLiteFilePicker(_ result: Result<[URL], Error>) {
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

    private func copyToDocuments(_ sourceURL: URL) -> URL {
        guard let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return sourceURL
        }
        var destURL = documentsDir.appendingPathComponent(sourceURL.lastPathComponent)

        if FileManager.default.fileExists(atPath: destURL.path) {
            let baseName = sourceURL.deletingPathExtension().lastPathComponent
            let ext = sourceURL.pathExtension
            let suffix = UUID().uuidString.prefix(8)
            destURL = documentsDir.appendingPathComponent("\(baseName)_\(suffix).\(ext)")
        }

        try? FileManager.default.copyItem(at: sourceURL, to: destURL)
        return destURL
    }

    func clearSelectedFile() {
        selectedFileURL = nil
        database = ""
    }

    func createNewDatabase() {
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

    // MARK: - Test Connection

    func testConnection(appState: AppState, secureStore: any SecureStore) async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }

        let tempId = UUID()
        var testConn = buildConnection()
        testConn.id = tempId

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

        defer {
            try? appState.connectionManager.deletePassword(for: tempId)
            try? secureStore.delete(forKey: "com.TablePro.sshpassword.\(tempId.uuidString)")
            try? secureStore.delete(forKey: "com.TablePro.keypassphrase.\(tempId.uuidString)")
            try? secureStore.delete(forKey: "com.TablePro.sshkeydata.\(tempId.uuidString)")
        }

        await appState.sshProvider.setPendingConnectionId(tempId)

        do {
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
            testResult = TestResult(success: false, message: classified.message, recovery: classified.recovery)
        }
    }

    // MARK: - Save

    func save(appState: AppState, secureStore: any SecureStore) -> DatabaseConnection? {
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
            return nil
        }

        return connection
    }

    func dismissCredentialError() {
        credentialError = nil
    }

    private func buildConnection() -> DatabaseConnection {
        var conn = DatabaseConnection(
            id: existingConnection?.id ?? UUID(),
            name: name.isEmpty ? (selectedFileURL?.lastPathComponent ?? host) : name,
            type: type,
            host: host,
            port: Int(port) ?? 3306,
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
}
