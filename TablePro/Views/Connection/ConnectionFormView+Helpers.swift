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
            if !hidePasswordField && !promptForPassword
                && PluginManager.shared.requiresAuthentication(for: type)
            {
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
        if sshState.enabled && sshState.profileId == nil {
            let sshPortValid = sshState.port.isEmpty
                || (Int(sshState.port).map { (1...65_535).contains($0) } ?? false)
            // Username may be empty: the runtime resolver fills it from
            // `~/.ssh/config` if the host is an alias with a User directive.
            let sshValid = !sshState.host.isEmpty && sshPortValid
            let authValid =
                sshState.authMethod == .password || sshState.authMethod == .sshAgent
                || sshState.authMethod == .keyboardInteractive || sshState.authMethod == .privateKey
            let jumpValid = sshState.jumpHosts.allSatisfy(\.isValid)
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
        let connectionFormLog = Logger(subsystem: "com.TablePro", category: "ConnectionForm")
        connectionFormLog.debug(
            "[trace] loadConnectionData connectionId=\(self.connectionId?.uuidString ?? "nil", privacy: .public) isNew=\(self.connectionId == nil)"
        )
        sshState.profiles = SSHProfileStorage.shared.loadProfiles()
        if let id = connectionId,
            let existing = storage.loadConnections().first(where: { $0.id == id })
        {
            connectionFormLog.debug(
                "[trace] loadConnectionData found existing id=\(existing.id.uuidString, privacy: .public) name='\(existing.name, privacy: .public)' promptForPassword=\(existing.promptForPassword)"
            )
            originalConnection = existing
            name = existing.name
            host = existing.host
            port = existing.port > 0 ? String(existing.port) : ""
            database = existing.database
            username = existing.username
            type = existing.type

            // Load SSH configuration
            sshState.load(from: existing)
            sshState.loadSecrets(connectionId: existing.id, storage: storage)

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
            externalAccess = existing.externalAccess
            localOnly = existing.localOnly

            // Load additional fields from connection
            additionalFieldValues = existing.additionalFields
            promptForPassword = existing.promptForPassword

            // Migrate legacy redisDatabase to additionalFields
            if additionalFieldValues["redisDatabase"] == nil,
               let rdb = existing.redisDatabase
            {
                additionalFieldValues["redisDatabase"] = String(rdb)
            }

            // Synthesize mongoHosts from host:port for existing MongoDB connections
            if existing.type.pluginTypeId == "MongoDB",
               additionalFieldValues["mongoHosts"]?.isEmpty != false
            {
                let existingHost = existing.host.isEmpty ? "localhost" : existing.host
                additionalFieldValues["mongoHosts"] = "\(existingHost):\(existing.port)"
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

            // Load connection password from Keychain
            if let savedPassword = storage.loadPassword(for: existing.id) {
                password = savedPassword
                connectionFormLog.debug(
                    "[trace] loadConnectionData password populated length=\(savedPassword.count)"
                )
            } else {
                connectionFormLog.debug(
                    "[trace] loadConnectionData password NOT populated (loadPassword returned nil)"
                )
            }
        }
        Task { @MainActor in
            hasLoadedData = true
        }
    }

    func saveConnection(connect: Bool = true) {
        let sshConfig = sshState.buildSSHConfig()

        let sslConfig = SSLConfiguration(
            mode: sslMode,
            caCertificatePath: sslCaCertPath,
            clientCertificatePath: sslClientCertPath,
            clientKeyPath: sslClientKeyPath
        )

        var finalHost = host.trimmingCharacters(in: .whitespaces).isEmpty ? "localhost" : host
        var finalPort = Int(port) ?? type.defaultPort
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)
        let finalUsername =
            trimmedUsername.isEmpty && PluginManager.shared.requiresAuthentication(for: type)
                ? "root" : trimmedUsername

        let finalId = connectionId ?? UUID()

        var finalAdditionalFields = additionalFieldValues

        if type.pluginTypeId == "MongoDB",
           let mongoHosts = finalAdditionalFields["mongoHosts"],
           !mongoHosts.isEmpty
        {
            let result = Self.normalizeMongoHosts(mongoHosts, defaultPort: type.defaultPort)
            finalAdditionalFields["mongoHosts"] = result.hosts
            finalHost = result.primaryHost
            finalPort = result.primaryPort
        }
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

        let sshTunnelMode = sshState.buildTunnelMode()
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
            sshProfileId: sshState.enabled ? sshState.profileId : nil,
            sshTunnelMode: sshTunnelMode,
            safeModeLevel: safeModeLevel,
            aiPolicy: aiPolicy,
            externalAccess: externalAccess,
            redisDatabase: additionalFieldValues["redisDatabase"].map { Int($0) ?? 0 },
            startupCommands: startupCommands.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : startupCommands,
            localOnly: localOnly,
            additionalFields: finalAdditionalFields.isEmpty ? nil : finalAdditionalFields
        )

        // Save passwords to Keychain
        if promptForPassword {
            storage.deletePassword(for: connectionToSave.id)
        } else if !password.isEmpty {
            storage.savePassword(password, for: connectionToSave.id)
        }
        // Only save SSH secrets per-connection when using inline config (not a profile)
        if sshState.enabled && sshState.profileId == nil {
            if (sshState.authMethod == .password || sshState.authMethod == .keyboardInteractive)
                && !sshState.password.isEmpty
            {
                storage.saveSSHPassword(sshState.password, for: connectionToSave.id)
            }
            if sshState.authMethod == .privateKey && !sshState.keyPassphrase.isEmpty {
                storage.saveKeyPassphrase(sshState.keyPassphrase, for: connectionToSave.id)
            }
            if sshState.totpMode == .autoGenerate && !sshState.totpSecret.isEmpty {
                storage.saveTOTPSecret(sshState.totpSecret, for: connectionToSave.id)
            } else {
                storage.deleteTOTPSecret(for: connectionToSave.id)
            }
        } else {
            storage.deleteSSHPassword(for: connectionToSave.id)
            storage.deleteKeyPassphrase(for: connectionToSave.id)
            storage.deleteTOTPSecret(for: connectionToSave.id)
        }

        // Save to storage
        var savedConnections = storage.loadConnections()
        if isNew {
            savedConnections.append(connectionToSave)
            storage.saveConnections(savedConnections)
            if !connectionToSave.localOnly {
                SyncChangeTracker.shared.markDirty(.connection, id: connectionToSave.id.uuidString)
            }
            ConnectionFormWindowFactory.closeAll()
            NotificationCenter.default.post(name: .connectionUpdated, object: nil)
            if connect {
                connectToDatabase(connectionToSave)
            }
        } else {
            if let index = savedConnections.firstIndex(where: { $0.id == connectionToSave.id }) {
                savedConnections[index] = connectionToSave
                storage.saveConnections(savedConnections)
                if !connectionToSave.localOnly {
                    SyncChangeTracker.shared.markDirty(.connection, id: connectionToSave.id.uuidString)
                }
            }
            ConnectionFormWindowFactory.closeAll()
            NotificationCenter.default.post(name: .connectionUpdated, object: nil)
        }
    }

    func deleteConnection() {
        guard let id = connectionId,
              let connection = storage.loadConnections().first(where: { $0.id == id }) else { return }
        storage.deleteConnection(connection)
        ConnectionFormWindowFactory.closeAll()
        NotificationCenter.default.post(name: .connectionUpdated, object: nil)
    }

    func connectToDatabase(_ connection: DatabaseConnection) {
        WelcomeWindowFactory.close()
        Task {
            do {
                try await TabRouter.shared.route(.openConnection(connection.id))
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
        WelcomeWindowFactory.openOrFront()
        guard !(error is CancellationError) else { return }
        Self.logger.error("Failed to connect: \(error.localizedDescription, privacy: .public)")
        AlertHelper.showErrorSheet(
            title: String(localized: "Connection Failed"),
            message: error.localizedDescription, window: nil
        )
    }

    func handleMissingPlugin(connection: DatabaseConnection) {
        closeConnectionWindows(for: connection.id)
        WelcomeWindowFactory.openOrFront()
        pluginInstallConnection = connection
    }

    func closeConnectionWindows(for connectionId: UUID) {
        for window in WindowLifecycleMonitor.shared.windows(for: connectionId) {
            window.close()
        }
    }

    func connectAfterInstall(_ connection: DatabaseConnection) {
        WelcomeWindowFactory.close()
        Task {
            do {
                try await TabRouter.shared.route(.openConnection(connection.id))
            } catch {
                handleConnectError(error, connection: connection)
            }
        }
    }

    func testConnection() {
        isTesting = true
        testSucceeded = false
        let window = NSApp.keyWindow

        let sshConfig = sshState.buildSSHConfig()

        let sslConfig = SSLConfiguration(
            mode: sslMode,
            caCertificatePath: sslCaCertPath,
            clientCertificatePath: sslClientCertPath,
            clientKeyPath: sslClientKeyPath
        )

        var testHost = host.trimmingCharacters(in: .whitespaces).isEmpty ? "localhost" : host
        var testPort = Int(port) ?? type.defaultPort
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

        if type.pluginTypeId == "MongoDB",
           let mongoHosts = finalAdditionalFields["mongoHosts"],
           !mongoHosts.isEmpty
        {
            let result = Self.normalizeMongoHosts(mongoHosts, defaultPort: type.defaultPort)
            finalAdditionalFields["mongoHosts"] = result.hosts
            testHost = result.primaryHost
            testPort = result.primaryPort
        }

        let testTunnelMode = sshState.buildTunnelMode()
        let testConn = DatabaseConnection(
            name: name,
            host: testHost,
            port: testPort,
            database: database,
            username: finalUsername,
            type: type,
            sshConfig: sshConfig,
            sslConfig: sslConfig,
            color: connectionColor,
            tagId: selectedTagId,
            groupId: selectedGroupId,
            sshProfileId: sshState.enabled ? sshState.profileId : nil,
            sshTunnelMode: testTunnelMode,
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
                if sshState.enabled && sshState.profileId == nil {
                    if (sshState.authMethod == .password || sshState.authMethod == .keyboardInteractive)
                        && !sshState.password.isEmpty
                    {
                        ConnectionStorage.shared.saveSSHPassword(sshState.password, for: testConn.id)
                    }
                    if sshState.authMethod == .privateKey && !sshState.keyPassphrase.isEmpty {
                        ConnectionStorage.shared.saveKeyPassphrase(sshState.keyPassphrase, for: testConn.id)
                    }
                    if sshState.totpMode == .autoGenerate && !sshState.totpSecret.isEmpty {
                        ConnectionStorage.shared.saveTOTPSecret(sshState.totpSecret, for: testConn.id)
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

                let sshPasswordForTest = sshState.profileId == nil ? sshState.password : nil
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
                    } else if let item = PluginDiagnosticItem.classify(
                        error: error, connection: testConn, username: finalUsername
                    ) {
                        pluginDiagnostic = item
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
                sshState.enabled = true
                sshState.host = sshHostValue
                sshState.port = parsed.sshPort.map(String.init) ?? ""
                sshState.username = parsed.sshUsername ?? ""
                if let sshPass = parsed.sshPassword, !sshPass.isEmpty {
                    sshState.password = sshPass
                }
                if parsed.usePrivateKey == true {
                    sshState.authMethod = .privateKey
                }
                if parsed.useSSHAgent == true {
                    sshState.authMethod = .sshAgent
                    sshState.applyAgentSocketPath(parsed.agentSocket ?? "")
                }
            }
            // Multi-host MongoDB support
            if let multiHost = parsed.multiHost, !multiHost.isEmpty {
                additionalFieldValues["mongoHosts"] = multiHost
            } else if parsed.type.pluginTypeId == "MongoDB" {
                let portStr = parsed.port.map(String.init) ?? String(parsed.type.defaultPort)
                additionalFieldValues["mongoHosts"] = "\(parsed.host):\(portStr)"
            }
            // Clear stale MongoDB fields before applying new import
            let mongoKeys = additionalFieldValues.keys.filter {
                ($0.hasPrefix("mongo") || $0.hasPrefix("mongoParam_")) && $0 != "mongoHosts"
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
            if parsed.type.pluginTypeId == "Redis", let redisDb = parsed.redisDatabase {
                additionalFieldValues["redisDatabase"] = String(redisDb)
            }
            if let svcName = parsed.oracleServiceName, !svcName.isEmpty {
                additionalFieldValues["oracleServiceName"] = svcName
            }
            if let hex = parsed.statusColor, !hex.isEmpty {
                connectionColor = ConnectionURLParser.connectionColor(fromHex: hex)
            }
            if let env = parsed.envTag, !env.isEmpty {
                selectedTagId = ConnectionURLParser.tagId(fromEnvName: env)
            }
            if parsed.type.pluginTypeId == "libSQL", !parsed.host.isEmpty {
                var urlString = "https://\(parsed.host)"
                if let port = parsed.port {
                    urlString += ":\(port)"
                }
                additionalFieldValues["databaseUrl"] = urlString
            }
            if parsed.type.pluginTypeId == "Cloudflare D1", !parsed.host.isEmpty {
                additionalFieldValues["cfAccountId"] = parsed.host
            }
            if let connectionName = parsed.connectionName, !connectionName.isEmpty {
                name = connectionName
            } else if name.isEmpty {
                name = parsed.suggestedName
            }
            if let level = parsed.safeModeLevel, let mode = SafeModeLevel.from(urlInteger: level) {
                safeModeLevel = mode
            }
        case .failure(let error):
            urlParseError = error.localizedDescription
        }
    }
}

// MARK: - Multi-Host Helpers

extension ConnectionFormView {
    struct NormalizedHosts {
        let hosts: String
        let primaryHost: String
        let primaryPort: Int
    }

    static func normalizeMongoHosts(_ raw: String, defaultPort: Int) -> NormalizedHosts {
        let normalized = raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { segment -> String in
                let trimmed = segment.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { return "localhost:\(defaultPort)" }
                if !trimmed.contains(":") { return "\(trimmed):\(defaultPort)" }
                return trimmed
            }
            .joined(separator: ",")
        let firstSegment = normalized.split(separator: ",").first.map(String.init) ?? normalized
        let parts = firstSegment.split(separator: ":", maxSplits: 1)
        var host = "localhost"
        var port = defaultPort
        if let first = parts.first {
            let derived = String(first).trimmingCharacters(in: .whitespaces)
            if !derived.isEmpty { host = derived }
        }
        if parts.count > 1, let p = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
            port = p
        }
        return NormalizedHosts(hosts: normalized, primaryHost: host, primaryPort: port)
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
            sshState.configEntries = entries
        }
    }
}

// MARK: - SSH Agent Helpers

extension ConnectionFormView {
    func applySSHAgentSocketPath(_ socketPath: String) {
        sshState.applyAgentSocketPath(socketPath)
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
