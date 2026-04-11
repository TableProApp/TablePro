//
//  ConnectionFormView+Helpers.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 16/12/25.
//

import os
import SwiftUI
import TableProPluginKit
import UniformTypeIdentifiers

// MARK: - Helpers

extension ConnectionFormView {
    var defaultPort: String {
        let port = type.defaultPort
        return port == 0 ? "" : String(port)
    }

    var filePathPrompt: String {
        let extensions = PluginManager.shared.fileExtensions(for: type)
        let ext = (extensions.first ?? "db")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !ext.isEmpty else { return "/path/to/database.db" }
        return "/path/to/database.\(ext)"
    }

    var isValid: Bool {
        let mode = PluginManager.shared.connectionMode(for: type)
        let supportsDatabaseField = mode == .fileBased
            || (mode == .apiOnly && PluginManager.shared.supportsDatabaseSwitching(for: type))
        var basicValid = !name.isEmpty && (supportsDatabaseField ? !database.isEmpty : true)
        if mode == .apiOnly {
            let hasRequiredFields = authSectionFields
                .filter(\.isRequired)
                .allSatisfy { !(additionalFieldValues[$0.id] ?? "").isEmpty }
            basicValid = basicValid && hasRequiredFields
            if !hidePasswordField && !promptForPassword {
                basicValid = basicValid && !password.isEmpty
            }
            for field in authSectionFields where field.isRequired && isFieldVisible(field) {
                if (additionalFieldValues[field.id] ?? "").isEmpty {
                    basicValid = false
                }
            }

            // Legacy DynamoDB-specific validation
            if hidePasswordField && additionalFieldValues["awsAuthMethod"] == "credentials" {
                let hasAccessKey = !(additionalFieldValues["awsAccessKeyId"] ?? "").isEmpty
                let hasSecret = !(additionalFieldValues["awsSecretAccessKey"] ?? "").isEmpty
                basicValid = basicValid && hasAccessKey && hasSecret
            }
        }
        if sshEnabled && sshProfileId == nil {
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

    var pgpassTrigger: Int {
        var hasher = Hasher()
        hasher.combine(host)
        hasher.combine(port)
        hasher.combine(database)
        hasher.combine(username)
        hasher.combine(additionalFieldValues["usePgpass"])
        return hasher.finalize()
    }

    func updatePgpassStatus() {
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

    func loadConnectionData() {
        sshProfiles = SSHProfileStorage.shared.loadProfiles()
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
            sshProfileId = existing.sshProfileId
            let profile = existing.sshProfileId.flatMap { id in sshProfiles.first { $0.id == id } }
            let effectiveSSH = existing.effectiveSSHConfig(profile: profile)
            sshEnabled = effectiveSSH.enabled

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
            promptForPassword = existing.promptForPassword

            // Migrate legacy redisDatabase to additionalFields
            if additionalFieldValues["redisDatabase"] == nil,
               let rdb = existing.redisDatabase
            {
                additionalFieldValues["redisDatabase"] = String(rdb)
            }

            for field in PluginManager.shared.additionalConnectionFields(for: existing.type) {
                if additionalFieldValues[field.id] == nil, let defaultValue = field.defaultValue {
                    additionalFieldValues[field.id] = defaultValue
                }
            }

            for field in PluginManager.shared.additionalConnectionFields(for: existing.type)
                where field.isSecure
            {
                if let secureValue = storage.loadPluginSecureField(fieldId: field.id, for: existing.id) {
                    additionalFieldValues[field.id] = secureValue
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

    func saveConnection() {
        let sshConfig: SSHConfiguration
        if let profileId = sshProfileId,
           let profile = sshProfiles.first(where: { $0.id == profileId })
        {
            sshConfig = profile.toSSHConfiguration()
        } else {
            sshConfig = SSHConfiguration(
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
        }

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

        let finalId = connectionId ?? UUID()

        var finalAdditionalFields = additionalFieldValues
        let trimmedScript = preConnectScript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedScript.isEmpty {
            finalAdditionalFields["preConnectScript"] = preConnectScript
        } else {
            finalAdditionalFields.removeValue(forKey: "preConnectScript")
        }

        finalAdditionalFields["promptForPassword"] = promptForPassword ? "true" : nil

        let secureFields = PluginManager.shared.additionalConnectionFields(for: type).filter(\.isSecure)
        for field in secureFields {
            if let value = finalAdditionalFields[field.id], !value.isEmpty {
                storage.savePluginSecureField(value, fieldId: field.id, for: finalId)
            } else {
                storage.deletePluginSecureField(fieldId: field.id, for: finalId)
            }
            finalAdditionalFields.removeValue(forKey: field.id)
        }

        let connectionToSave = DatabaseConnection(
            id: finalId,
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
            sshProfileId: sshProfileId,
            safeModeLevel: safeModeLevel,
            aiPolicy: aiPolicy,
            redisDatabase: additionalFieldValues["redisDatabase"].map { Int($0) ?? 0 },
            startupCommands: startupCommands.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : startupCommands,
            additionalFields: finalAdditionalFields.isEmpty ? nil : finalAdditionalFields
        )

        // Save passwords to Keychain
        if promptForPassword {
            storage.deletePassword(for: connectionToSave.id)
        } else if !password.isEmpty {
            storage.savePassword(password, for: connectionToSave.id)
        }
        // Only save SSH secrets per-connection when using inline config (not a profile)
        if sshEnabled && sshProfileId == nil {
            if (sshAuthMethod == .password || sshAuthMethod == .keyboardInteractive)
                && !sshPassword.isEmpty
            {
                storage.saveSSHPassword(sshPassword, for: connectionToSave.id)
            }
            if sshAuthMethod == .privateKey && !keyPassphrase.isEmpty {
                storage.saveKeyPassphrase(keyPassphrase, for: connectionToSave.id)
            }
            if totpMode == .autoGenerate && !totpSecret.isEmpty {
                storage.saveTOTPSecret(totpSecret, for: connectionToSave.id)
            } else {
                storage.deleteTOTPSecret(for: connectionToSave.id)
            }
        } else {
            // Clean up stale per-connection SSH secrets when using a profile or SSH disabled
            storage.deleteSSHPassword(for: connectionToSave.id)
            storage.deleteKeyPassphrase(for: connectionToSave.id)
            storage.deleteTOTPSecret(for: connectionToSave.id)
        }

        // Save to storage
        var savedConnections = storage.loadConnections()
        if isNew {
            savedConnections.append(connectionToSave)
            storage.saveConnections(savedConnections)
            SyncChangeTracker.shared.markDirty(.connection, id: connectionToSave.id.uuidString)
            NSApplication.shared.closeWindows(withId: "connection-form")
            NotificationCenter.default.post(name: .connectionUpdated, object: nil)
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

    func deleteConnection() {
        guard let id = connectionId,
              let connection = storage.loadConnections().first(where: { $0.id == id }) else { return }
        storage.deleteConnection(connection)
        NSApplication.shared.closeWindows(withId: "connection-form")
        NotificationCenter.default.post(name: .connectionUpdated, object: nil)
    }

    func connectToDatabase(_ connection: DatabaseConnection) {
        if WindowOpener.shared.openWindow == nil {
            WindowOpener.shared.openWindow = openWindow
        }
        WindowOpener.shared.openNativeTab(EditorTabPayload(connectionId: connection.id, intent: .restoreOrDefault))
        NSApplication.shared.closeWindows(withId: "welcome")

        Task {
            do {
                try await dbManager.connectToSession(connection)
            } catch {
                handleConnectError(error, connection: connection)
            }
        }
    }

    func handleConnectError(_ error: Error, connection: DatabaseConnection) {
        if case PluginError.pluginNotInstalled = error {
            handleMissingPlugin(connection: connection)
            return
        }
        closeConnectionWindows(for: connection.id)
        openWindow(id: "welcome")
        guard !(error is CancellationError) else { return }
        Self.logger.error("Failed to connect: \(error.localizedDescription, privacy: .public)")
        AlertHelper.showErrorSheet(
            title: String(localized: "Connection Failed"),
            message: error.localizedDescription, window: nil
        )
    }

    func handleMissingPlugin(connection: DatabaseConnection) {
        closeConnectionWindows(for: connection.id)
        openWindow(id: "welcome")
        pluginInstallConnection = connection
    }

    func closeConnectionWindows(for connectionId: UUID) {
        for window in WindowLifecycleMonitor.shared.windows(for: connectionId) {
            window.close()
        }
    }

    func connectAfterInstall(_ connection: DatabaseConnection) {
        if WindowOpener.shared.openWindow == nil {
            WindowOpener.shared.openWindow = openWindow
        }
        WindowOpener.shared.openNativeTab(EditorTabPayload(connectionId: connection.id, intent: .restoreOrDefault))
        NSApplication.shared.closeWindows(withId: "welcome")

        Task {
            do {
                try await dbManager.connectToSession(connection)
            } catch {
                handleConnectError(error, connection: connection)
            }
        }
    }

    func testConnection() {
        isTesting = true
        testSucceeded = false
        let window = NSApp.keyWindow

        let sshConfig: SSHConfiguration
        if let profileId = sshProfileId,
           let profile = sshProfiles.first(where: { $0.id == profileId })
        {
            sshConfig = profile.toSSHConfiguration()
        } else {
            sshConfig = SSHConfiguration(
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
        }

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
            sshProfileId: sshProfileId,
            redisDatabase: additionalFieldValues["redisDatabase"].map { Int($0) ?? 0 },
            startupCommands: startupCommands.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : startupCommands,
            additionalFields: finalAdditionalFields.isEmpty ? nil : finalAdditionalFields
        )

        Task {
            do {
                // Save passwords temporarily for test (skip when prompt mode is active)
                if !password.isEmpty && !promptForPassword {
                    ConnectionStorage.shared.savePassword(password, for: testConn.id)
                }
                // Only write inline SSH secrets when not using a profile
                if sshEnabled && sshProfileId == nil {
                    if (sshAuthMethod == .password || sshAuthMethod == .keyboardInteractive)
                        && !sshPassword.isEmpty
                    {
                        ConnectionStorage.shared.saveSSHPassword(sshPassword, for: testConn.id)
                    }
                    if sshAuthMethod == .privateKey && !keyPassphrase.isEmpty {
                        ConnectionStorage.shared.saveKeyPassphrase(keyPassphrase, for: testConn.id)
                    }
                    if totpMode == .autoGenerate && !totpSecret.isEmpty {
                        ConnectionStorage.shared.saveTOTPSecret(totpSecret, for: testConn.id)
                    }
                }

                for field in PluginManager.shared.additionalConnectionFields(for: type)
                    where field.isSecure
                {
                    if let value = additionalFieldValues[field.id], !value.isEmpty {
                        ConnectionStorage.shared.savePluginSecureField(
                            value, fieldId: field.id, for: testConn.id
                        )
                    }
                }

                let sshPasswordForTest = sshProfileId == nil ? sshPassword : nil
                let isApiOnly = PluginManager.shared.connectionMode(for: type) == .apiOnly
                let testPwOverride: String? = promptForPassword
                    ? (password.isEmpty
                        ? await PasswordPromptHelper.prompt(
                            connectionName: name.isEmpty ? host : name,
                            isAPIToken: isApiOnly,
                            window: NSApp.keyWindow
                        )
                        : password)
                    : nil
                guard !promptForPassword || testPwOverride != nil else {
                    cleanupTestSecrets(for: testConn.id)
                    isTesting = false
                    return
                }
                let success = try await DatabaseManager.shared.testConnection(
                    testConn,
                    sshPassword: sshPasswordForTest,
                    passwordOverride: testPwOverride
                )
                cleanupTestSecrets(for: testConn.id)
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
                cleanupTestSecrets(for: testConn.id)
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

    func browseForFile() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.database, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                database = url.path(percentEncoded: false)
            }
        }
    }

    func installPlugin(for databaseType: DatabaseType) {
        isInstallingPlugin = true
        Task {
            do {
                try await PluginManager.shared.installMissingPlugin(for: databaseType) { _ in }
                if type == databaseType {
                    for field in PluginManager.shared.additionalConnectionFields(for: databaseType) {
                        if additionalFieldValues[field.id] == nil, let defaultValue = field.defaultValue {
                            additionalFieldValues[field.id] = defaultValue
                        }
                    }
                }
            } catch {
                pluginInstallError = error.localizedDescription
            }
            isInstallingPlugin = false
        }
    }

    func parseConnectionURL() {
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
            // Clear stale MongoDB fields before applying new import
            let mongoKeys = additionalFieldValues.keys.filter {
                $0.hasPrefix("mongo") || $0.hasPrefix("mongoParam_")
            }
            for key in mongoKeys {
                additionalFieldValues.removeValue(forKey: key)
            }
            if let authSourceValue = parsed.authSource, !authSourceValue.isEmpty {
                additionalFieldValues["mongoAuthSource"] = authSourceValue
            }
            if parsed.useSrv {
                additionalFieldValues["mongoUseSrv"] = "true"
                if sslMode == .disabled {
                    sslMode = .required
                }
            }
            for (key, value) in parsed.mongoQueryParams where !value.isEmpty {
                switch key {
                case "authMechanism":
                    additionalFieldValues["mongoAuthMechanism"] = value
                case "replicaSet":
                    additionalFieldValues["mongoReplicaSet"] = value
                default:
                    additionalFieldValues["mongoParam_\(key)"] = value
                }
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
}

// MARK: - Test Helpers

extension ConnectionFormView {
    func cleanupTestSecrets(for testId: UUID) {
        ConnectionStorage.shared.deletePassword(for: testId)
        ConnectionStorage.shared.deleteSSHPassword(for: testId)
        ConnectionStorage.shared.deleteKeyPassphrase(for: testId)
        ConnectionStorage.shared.deleteTOTPSecret(for: testId)
        let secureFieldIds = PluginManager.shared.additionalConnectionFields(for: type)
            .filter(\.isSecure).map(\.id)
        ConnectionStorage.shared.deleteAllPluginSecureFields(for: testId, fieldIds: secureFieldIds)
    }

    func loadSSHConfig() {
        Task {
            let entries = await Task.detached { SSHConfigParser.parse() }.value
            sshConfigEntries = entries
        }
    }
}

// MARK: - SSH Agent Helpers

extension ConnectionFormView {
    func applySSHAgentSocketPath(_ socketPath: String) {
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

enum PgpassStatus {
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

// MARK: - Pgpass Status View

extension ConnectionFormView {
    @ViewBuilder
    var pgpassStatusView: some View {
        switch pgpassStatus {
        case .notChecked:
            EmptyView()
        case .fileNotFound:
            Label(
                String(localized: "~/.pgpass not found"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(Color(nsColor: .systemYellow))
            .font(.caption)
        case .badPermissions:
            Label(
                String(localized: "~/.pgpass has incorrect permissions (needs chmod 0600)"),
                systemImage: "xmark.circle.fill"
            )
            .foregroundStyle(Color(nsColor: .systemRed))
            .font(.caption)
        case .matchFound:
            Label(
                String(localized: "~/.pgpass found — matching entry exists"),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(Color(nsColor: .systemGreen))
            .font(.caption)
        case .noMatch:
            Label(
                String(localized: "~/.pgpass found — no matching entry"),
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(Color(nsColor: .systemYellow))
            .font(.caption)
        }
    }
}
