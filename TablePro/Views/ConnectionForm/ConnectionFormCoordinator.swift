//
//  ConnectionFormCoordinator.swift
//  TablePro
//

import AppKit
import os
import SwiftUI
import TableProPluginKit

@MainActor
final class WeakCoordinatorRef {
    weak var value: ConnectionFormCoordinator?

    init(_ value: ConnectionFormCoordinator? = nil) {
        self.value = value
    }
}

@Observable
@MainActor
final class ConnectionFormCoordinator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionFormCoordinator")

    let connectionId: UUID?
    private(set) var originalConnection: DatabaseConnection?

    var network: NetworkPaneViewModel
    var auth: AuthPaneViewModel
    var ssh: SSHPaneViewModel
    var ssl: SSLPaneViewModel
    var customization: CustomizationPaneViewModel
    var advanced: AdvancedPaneViewModel
    var aiRules: AIRulesPaneViewModel

    var selectedPane: ConnectionFormPane = .general
    var hasLoadedData: Bool = false

    var isTesting: Bool = false
    var testSucceeded: Bool = false
    var testTask: Task<Void, Never>?

    var isInstallingPlugin: Bool = false
    var pluginInstallError: String?
    var pluginInstallConnection: DatabaseConnection?
    var pluginDiagnostic: PluginDiagnosticItem?

    var saveError: String?

    var clipboardCandidate: ParsedConnection?
    var clipboardBannerDismissed: Bool = false


    private var temporaryTestIds: Set<UUID> = []

    @ObservationIgnored let services: AppServices
    var storage: ConnectionStorage { services.connectionStorage }
    var dismissAction: (() -> Void)?

    var isNew: Bool { connectionId == nil }

    var visiblePanes: [ConnectionFormPane] {
        var panes: [ConnectionFormPane] = [.general]
        if services.pluginManager.supportsSSH(for: network.type) {
            panes.append(.ssh)
        }
        if services.pluginManager.supportsSSL(for: network.type) {
            panes.append(.ssl)
        }
        panes.append(.customization)
        panes.append(.advanced)
        panes.append(.aiRules)
        return panes
    }

    var isFormValid: Bool {
        network.validationIssues.isEmpty
            && auth.validationIssues.isEmpty
            && ssh.validationIssues.isEmpty
            && ssl.validationIssues.isEmpty
            && customization.validationIssues.isEmpty
            && advanced.validationIssues.isEmpty
    }

    private let pendingInitialType: DatabaseType?
    private let pendingInitialParsedURL: ParsedConnectionURL?

    init(
        connectionId: UUID?,
        initialType: DatabaseType? = nil,
        initialParsedURL: ParsedConnectionURL? = nil,
        services: AppServices = .live
    ) {
        self.connectionId = connectionId
        self.pendingInitialType = initialType
        self.pendingInitialParsedURL = initialParsedURL
        self.services = services
        self.network = NetworkPaneViewModel()
        self.auth = AuthPaneViewModel()
        self.ssh = SSHPaneViewModel()
        self.ssl = SSLPaneViewModel()
        self.customization = CustomizationPaneViewModel()
        self.advanced = AdvancedPaneViewModel()
        self.aiRules = AIRulesPaneViewModel()

        let ref = WeakCoordinatorRef(self)
        network.coordinator = ref
        auth.coordinator = ref
        ssh.coordinator = ref
        ssl.coordinator = ref
        customization.coordinator = ref
        advanced.coordinator = ref
        aiRules.coordinator = ref
    }

    /// Performs the one-time side-effecting setup: applying initial type
    /// defaults, loading the existing connection from storage, and overlaying
    /// any parsed URL the form was opened with. Idempotent.
    func start() {
        guard !hasLoadedData else { return }

        let resolvedInitialType = pendingInitialParsedURL?.type ?? pendingInitialType
        if let resolvedInitialType {
            network.type = resolvedInitialType
            network.port = String(resolvedInitialType.defaultPort)
            applyTypeDefaults(resolvedInitialType, includeNetwork: true)
        }

        loadInitialData()

        if let parsed = pendingInitialParsedURL {
            applyParsed(parsed)
        }
    }

    // MARK: - Lifecycle

    private func loadInitialData() {
        Self.logger.debug(
            "[trace] load connectionId=\(self.connectionId?.uuidString ?? "nil", privacy: .public) isNew=\(self.isNew)"
        )
        ssh.loadProfiles()
        ssh.loadSSHConfig()
        if let id = connectionId,
           let existing = storage.loadConnections().first(where: { $0.id == id })
        {
            Self.logger.debug(
                "[trace] load found existing id=\(existing.id.uuidString, privacy: .public) name='\(existing.name, privacy: .public)' promptForPassword=\(existing.promptForPassword)"
            )
            originalConnection = existing
            network.load(from: existing)
            auth.load(from: existing, storage: storage)
            ssh.load(from: existing, storage: storage)
            ssl.load(from: existing)
            customization.load(from: existing)
            advanced.load(from: existing)
            aiRules.load(from: existing)
        }
        hasLoadedData = true
    }

    func cancel() {
        dismissAction?()
    }

    func deleteCurrent() {
        guard let id = connectionId,
              let connection = storage.loadConnections().first(where: { $0.id == id }) else { return }
        storage.deleteConnection(connection)
        dismissAction?()
        NotificationCenter.default.post(name: .connectionUpdated, object: nil)
    }

    // MARK: - Type change

    func didChangeType(_ newType: DatabaseType) {
        testSucceeded = false
        if hasLoadedData {
            applyTypeDefaults(newType, includeNetwork: true)
            auth.resetForType(newType)
            advanced.resetForType(newType)
        }
        if !visiblePanes.contains(selectedPane) {
            selectedPane = .general
        }
        isInstallingPlugin = false
        pluginInstallError = nil
    }

    private func applyTypeDefaults(_ newType: DatabaseType, includeNetwork: Bool) {
        if includeNetwork {
            network.applyTypeDefaults(forNewType: newType)
        }
    }

    // MARK: - Save

    func save() {
        saveConnection(connect: false)
    }

    func saveAndConnect() {
        saveConnection(connect: isNew)
    }

    private func saveConnection(connect: Bool) {
        let sshConfig = ssh.state.buildSSHConfig()
        let sslConfig = ssl.buildConfig()

        var finalHost = network.host.trimmingCharacters(in: .whitespaces).isEmpty
            ? "localhost" : network.host
        var finalPort = Int(network.port) ?? network.type.defaultPort
        let trimmedUsername = auth.username.trimmingCharacters(in: .whitespaces)
        let finalUsername =
            trimmedUsername.isEmpty && services.pluginManager.requiresAuthentication(for: network.type)
                ? "root" : trimmedUsername

        let finalId = connectionId ?? UUID()

        var finalAdditionalFields: [String: String] = [:]
        network.write(into: &finalAdditionalFields)
        auth.write(into: &finalAdditionalFields)
        advanced.write(into: &finalAdditionalFields)

        if network.type.pluginTypeId == "MongoDB",
           let mongoHosts = finalAdditionalFields["mongoHosts"],
           !mongoHosts.isEmpty
        {
            let result = Self.normalizeMongoHosts(mongoHosts, defaultPort: network.type.defaultPort)
            finalAdditionalFields["mongoHosts"] = result.hosts
            finalHost = result.primaryHost
            finalPort = result.primaryPort
        }

        let trimmedScript = advanced.preConnectScript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedScript.isEmpty {
            finalAdditionalFields["preConnectScript"] = advanced.preConnectScript
        } else {
            finalAdditionalFields.removeValue(forKey: "preConnectScript")
        }

        finalAdditionalFields["promptForPassword"] = auth.promptForPassword ? "true" : nil

        let secureFields = services.pluginManager.additionalConnectionFields(for: network.type)
            .filter(\.isSecure)
        for field in secureFields {
            if let value = finalAdditionalFields[field.id], !value.isEmpty {
                storage.savePluginSecureField(value, fieldId: field.id, for: finalId)
            } else {
                storage.deletePluginSecureField(fieldId: field.id, for: finalId)
            }
            finalAdditionalFields.removeValue(forKey: field.id)
        }

        let sshTunnelMode = ssh.state.buildTunnelMode()
        let connectionToSave = DatabaseConnection(
            id: finalId,
            name: network.name,
            host: finalHost,
            port: finalPort,
            database: network.database,
            username: finalUsername,
            type: network.type,
            sshConfig: sshConfig,
            sslConfig: sslConfig,
            color: customization.color,
            tagId: customization.tagId,
            groupId: customization.groupId,
            sshProfileId: ssh.state.enabled ? ssh.state.profileId : nil,
            sshTunnelMode: sshTunnelMode,
            safeModeLevel: customization.safeModeLevel,
            aiPolicy: advanced.aiPolicy,
            aiRules: aiRules.trimmedRules,
            externalAccess: advanced.externalAccess,
            redisDatabase: advanced.additionalFieldValues["redisDatabase"].map { Int($0) ?? 0 },
            startupCommands: advanced.startupCommands.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : advanced.startupCommands,
            localOnly: advanced.localOnly,
            additionalFields: finalAdditionalFields.isEmpty ? nil : finalAdditionalFields
        )

        if auth.promptForPassword {
            storage.deletePassword(for: connectionToSave.id)
        } else if !auth.password.isEmpty {
            storage.savePassword(auth.password, for: connectionToSave.id)
        }

        if ssh.state.enabled && ssh.state.profileId == nil {
            if (ssh.state.authMethod == .password || ssh.state.authMethod == .keyboardInteractive)
                && !ssh.state.password.isEmpty
            {
                storage.saveSSHPassword(ssh.state.password, for: connectionToSave.id)
            }
            if ssh.state.authMethod == .privateKey && !ssh.state.keyPassphrase.isEmpty {
                storage.saveKeyPassphrase(ssh.state.keyPassphrase, for: connectionToSave.id)
            }
            if ssh.state.totpMode == .autoGenerate && !ssh.state.totpSecret.isEmpty {
                storage.saveTOTPSecret(ssh.state.totpSecret, for: connectionToSave.id)
            } else {
                storage.deleteTOTPSecret(for: connectionToSave.id)
            }
        } else {
            storage.deleteSSHPassword(for: connectionToSave.id)
            storage.deleteKeyPassphrase(for: connectionToSave.id)
            storage.deleteTOTPSecret(for: connectionToSave.id)
        }

        var savedConnections = storage.loadConnections()
        if isNew {
            savedConnections.append(connectionToSave)
            storage.saveConnections(savedConnections)
            if !connectionToSave.localOnly {
                services.syncTracker.markDirty(.connection, id: connectionToSave.id.uuidString)
            }
            dismissAction?()
            NotificationCenter.default.post(name: .connectionUpdated, object: nil)
            if connect {
                connectToDatabase(connectionToSave)
            }
        } else {
            guard let index = savedConnections.firstIndex(where: { $0.id == connectionToSave.id }) else {
                saveError = String(localized: "This connection was deleted on another device or window. Your changes were not saved.")
                return
            }
            savedConnections[index] = connectionToSave
            storage.saveConnections(savedConnections)
            if !connectionToSave.localOnly {
                services.syncTracker.markDirty(.connection, id: connectionToSave.id.uuidString)
            }
            dismissAction?()
            NotificationCenter.default.post(name: .connectionUpdated, object: nil)
        }
    }

    func connectToDatabase(_ connection: DatabaseConnection) {
        WindowOpener.shared.orderOutWelcome()
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
        WindowOpener.shared.openWelcome()
        guard !(error is CancellationError) else { return }
        Self.logger.error("Failed to connect: \(error.localizedDescription, privacy: .public)")
        AlertHelper.showErrorSheet(
            title: String(localized: "Connection Failed"),
            message: error.localizedDescription,
            window: nil
        )
    }

    func handleMissingPlugin(connection: DatabaseConnection) {
        closeConnectionWindows(for: connection.id)
        WindowOpener.shared.openWelcome()
        pluginInstallConnection = connection
    }

    func connectAfterInstall(_ connection: DatabaseConnection) {
        WindowOpener.shared.orderOutWelcome()
        Task {
            do {
                try await TabRouter.shared.route(.openConnection(connection.id))
            } catch {
                handleConnectError(error, connection: connection)
            }
        }
    }

    private func closeConnectionWindows(for connectionId: UUID) {
        for window in WindowLifecycleMonitor.shared.windows(for: connectionId) {
            window.close()
        }
    }

    // MARK: - Test

    func test() {
        guard testTask == nil else { return }
        isTesting = true
        testSucceeded = false
        let window = NSApp.keyWindow

        let sshConfig = ssh.state.buildSSHConfig()
        let sslConfig = ssl.buildConfig()

        var testHost = network.host.trimmingCharacters(in: .whitespaces).isEmpty
            ? "localhost" : network.host
        var testPort = Int(network.port) ?? network.type.defaultPort
        let trimmedUsername = auth.username.trimmingCharacters(in: .whitespaces)
        let finalUsername =
            trimmedUsername.isEmpty && services.pluginManager.requiresAuthentication(for: network.type)
                ? "root" : trimmedUsername

        var finalAdditionalFields: [String: String] = [:]
        network.write(into: &finalAdditionalFields)
        auth.write(into: &finalAdditionalFields)
        advanced.write(into: &finalAdditionalFields)

        let trimmedScript = advanced.preConnectScript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedScript.isEmpty {
            finalAdditionalFields["preConnectScript"] = advanced.preConnectScript
        } else {
            finalAdditionalFields.removeValue(forKey: "preConnectScript")
        }

        if network.type.pluginTypeId == "MongoDB",
           let mongoHosts = finalAdditionalFields["mongoHosts"],
           !mongoHosts.isEmpty
        {
            let result = Self.normalizeMongoHosts(mongoHosts, defaultPort: network.type.defaultPort)
            finalAdditionalFields["mongoHosts"] = result.hosts
            testHost = result.primaryHost
            testPort = result.primaryPort
        }

        let testTunnelMode = ssh.state.buildTunnelMode()
        let testConn = DatabaseConnection(
            name: network.name,
            host: testHost,
            port: testPort,
            database: network.database,
            username: finalUsername,
            type: network.type,
            sshConfig: sshConfig,
            sslConfig: sslConfig,
            color: customization.color,
            tagId: customization.tagId,
            groupId: customization.groupId,
            sshProfileId: ssh.state.enabled ? ssh.state.profileId : nil,
            sshTunnelMode: testTunnelMode,
            redisDatabase: advanced.additionalFieldValues["redisDatabase"].map { Int($0) ?? 0 },
            startupCommands: advanced.startupCommands.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : advanced.startupCommands,
            additionalFields: finalAdditionalFields.isEmpty ? nil : finalAdditionalFields
        )
        temporaryTestIds.insert(testConn.id)

        let password = auth.password
        let promptForPassword = auth.promptForPassword
        let connectionType = network.type
        let displayName = network.name.isEmpty ? network.host : network.name
        let sshState = ssh.state
        let additionalFieldValues = finalAdditionalFields

        testTask = Task { [weak self] in
            do {
                if !password.isEmpty && !promptForPassword {
                    services.connectionStorage.savePassword(password, for: testConn.id)
                }
                if sshState.enabled && sshState.profileId == nil {
                    if (sshState.authMethod == .password || sshState.authMethod == .keyboardInteractive)
                        && !sshState.password.isEmpty
                    {
                        services.connectionStorage.saveSSHPassword(sshState.password, for: testConn.id)
                    }
                    if sshState.authMethod == .privateKey && !sshState.keyPassphrase.isEmpty {
                        services.connectionStorage.saveKeyPassphrase(sshState.keyPassphrase, for: testConn.id)
                    }
                    if sshState.totpMode == .autoGenerate && !sshState.totpSecret.isEmpty {
                        services.connectionStorage.saveTOTPSecret(sshState.totpSecret, for: testConn.id)
                    }
                }

                for field in services.pluginManager.additionalConnectionFields(for: connectionType)
                    where field.isSecure
                {
                    if let value = additionalFieldValues[field.id], !value.isEmpty {
                        services.connectionStorage.savePluginSecureField(
                            value, fieldId: field.id, for: testConn.id
                        )
                    }
                }

                let sshPasswordForTest = sshState.profileId == nil ? sshState.password : nil
                let isApiOnly = services.pluginManager.connectionMode(for: connectionType) == .apiOnly
                let testPwOverride: String? = promptForPassword
                    ? (password.isEmpty
                        ? await PasswordPromptHelper.prompt(
                            connectionName: displayName,
                            isAPIToken: isApiOnly,
                            window: NSApp.keyWindow
                        )
                        : password)
                    : nil

                guard !promptForPassword || testPwOverride != nil else {
                    await MainActor.run {
                        self?.cleanupTestSecrets(for: testConn.id)
                        self?.isTesting = false
                        self?.testTask = nil
                    }
                    return
                }

                let success = try await services.databaseManager.testConnection(
                    testConn,
                    sshPassword: sshPasswordForTest,
                    passwordOverride: testPwOverride
                )
                await MainActor.run {
                    self?.cleanupTestSecrets(for: testConn.id)
                    self?.isTesting = false
                    self?.testTask = nil
                    if success {
                        self?.testSucceeded = true
                    } else {
                        AlertHelper.showErrorSheet(
                            title: String(localized: "Connection Test Failed"),
                            message: String(localized: "Connection test failed"),
                            window: window
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    self?.cleanupTestSecrets(for: testConn.id)
                    self?.isTesting = false
                    self?.testSucceeded = false
                    self?.testTask = nil
                    if case PluginError.pluginNotInstalled = error {
                        self?.pluginInstallConnection = testConn
                    } else if let item = PluginDiagnosticItem.classify(
                        error: error, connection: testConn, username: finalUsername
                    ) {
                        self?.pluginDiagnostic = item
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

    func cleanupTestSecrets(for testId: UUID) {
        services.connectionStorage.deletePassword(for: testId)
        services.connectionStorage.deleteSSHPassword(for: testId)
        services.connectionStorage.deleteKeyPassphrase(for: testId)
        services.connectionStorage.deleteTOTPSecret(for: testId)
        let secureFieldIds = services.pluginManager.additionalConnectionFields(for: network.type)
            .filter(\.isSecure).map(\.id)
        services.connectionStorage.deleteAllPluginSecureFields(for: testId, fieldIds: secureFieldIds)
        temporaryTestIds.remove(testId)
    }

    // MARK: - Plugin install

    func installPlugin(for databaseType: DatabaseType) {
        isInstallingPlugin = true
        Task { [weak self] in
            do {
                try await services.pluginManager.installMissingPlugin(for: databaseType) { _ in }
                await MainActor.run {
                    guard let self else { return }
                    if self.network.type == databaseType {
                        for field in services.pluginManager.additionalConnectionFields(for: databaseType) {
                            if self.targetValues(for: field.section)[field.id] == nil,
                               let defaultValue = field.defaultValue
                            {
                                self.setFieldValue(defaultValue, fieldId: field.id, section: field.section)
                            }
                        }
                    }
                    self.isInstallingPlugin = false
                }
            } catch {
                await MainActor.run {
                    self?.pluginInstallError = error.localizedDescription
                    self?.isInstallingPlugin = false
                }
            }
        }
    }

    private func targetValues(for section: FieldSection) -> [String: String] {
        switch section {
        case .authentication: return auth.additionalFieldValues
        case .connection: return network.additionalFieldValues
        case .advanced: return advanced.additionalFieldValues
        }
    }

    private func setFieldValue(_ value: String, fieldId: String, section: FieldSection) {
        switch section {
        case .authentication:
            auth.additionalFieldValues[fieldId] = value
        case .connection:
            network.additionalFieldValues[fieldId] = value
        case .advanced:
            advanced.additionalFieldValues[fieldId] = value
        }
    }

    // MARK: - URL import

    private func applyParsed(_ parsed: ParsedConnectionURL) {
        let oldType = network.type
        network.type = parsed.type
        if oldType != parsed.type {
            applyTypeDefaults(parsed.type, includeNetwork: false)
            auth.resetForType(parsed.type)
            advanced.resetForType(parsed.type)
        }

        network.host = parsed.host
        network.port = parsed.port.map(String.init) ?? String(parsed.type.defaultPort)
        network.database = parsed.database
        auth.username = parsed.username
        auth.password = parsed.password
        ssl.mode = parsed.sslMode ?? .disabled

        if let sshHostValue = parsed.sshHost {
            ssh.state.enabled = true
            ssh.state.host = sshHostValue
            ssh.state.port = parsed.sshPort.map(String.init) ?? ""
            ssh.state.username = parsed.sshUsername ?? ""
            if let sshPass = parsed.sshPassword, !sshPass.isEmpty {
                ssh.state.password = sshPass
            }
            if parsed.usePrivateKey == true {
                ssh.state.authMethod = .privateKey
            }
            if parsed.useSSHAgent == true {
                ssh.state.authMethod = .sshAgent
                ssh.state.applyAgentSocketPath(parsed.agentSocket ?? "")
            }
        }

        if let multiHost = parsed.multiHost, !multiHost.isEmpty {
            network.additionalFieldValues["mongoHosts"] = multiHost
        } else if parsed.type.pluginTypeId == "MongoDB" {
            let portStr = parsed.port.map(String.init) ?? String(parsed.type.defaultPort)
            network.additionalFieldValues["mongoHosts"] = "\(parsed.host):\(portStr)"
        }

        let mongoKeysAuth = auth.additionalFieldValues.keys.filter {
            ($0.hasPrefix("mongo") || $0.hasPrefix("mongoParam_")) && $0 != "mongoHosts"
        }
        for key in mongoKeysAuth {
            auth.additionalFieldValues.removeValue(forKey: key)
        }
        let mongoKeysAdvanced = advanced.additionalFieldValues.keys.filter {
            ($0.hasPrefix("mongo") || $0.hasPrefix("mongoParam_")) && $0 != "mongoHosts"
        }
        for key in mongoKeysAdvanced {
            advanced.additionalFieldValues.removeValue(forKey: key)
        }

        if let authSourceValue = parsed.authSource, !authSourceValue.isEmpty {
            writeFieldByRegistry("mongoAuthSource", value: authSourceValue)
        }
        if parsed.useSrv {
            writeFieldByRegistry("mongoUseSrv", value: "true")
            if ssl.mode == .disabled {
                ssl.mode = .required
            }
        }
        for (key, value) in parsed.mongoQueryParams where !value.isEmpty {
            switch key {
            case "authMechanism":
                writeFieldByRegistry("mongoAuthMechanism", value: value)
            case "replicaSet":
                writeFieldByRegistry("mongoReplicaSet", value: value)
            default:
                writeFieldByRegistry("mongoParam_\(key)", value: value)
            }
        }
        if parsed.type.pluginTypeId == "Redis", let redisDb = parsed.redisDatabase {
            writeFieldByRegistry("redisDatabase", value: String(redisDb))
        }
        if let svcName = parsed.oracleServiceName, !svcName.isEmpty {
            writeFieldByRegistry("oracleServiceName", value: svcName)
        }
        if let hex = parsed.statusColor, !hex.isEmpty {
            customization.color = ConnectionURLParser.connectionColor(fromHex: hex)
        }
        if let env = parsed.envTag, !env.isEmpty {
            customization.tagId = ConnectionURLParser.tagId(fromEnvName: env)
        }
        if parsed.type.pluginTypeId == "libSQL", !parsed.host.isEmpty {
            var urlString = "https://\(parsed.host)"
            if let port = parsed.port {
                urlString += ":\(port)"
            }
            writeFieldByRegistry("databaseUrl", value: urlString)
        }
        if parsed.type.pluginTypeId == "Cloudflare D1", !parsed.host.isEmpty {
            writeFieldByRegistry("cfAccountId", value: parsed.host)
        }
        if let connectionName = parsed.connectionName, !connectionName.isEmpty {
            network.name = connectionName
        } else if network.name.isEmpty {
            network.name = parsed.suggestedName
        }
        if let level = parsed.safeModeLevel, let mode = SafeModeLevel.from(urlInteger: level) {
            customization.safeModeLevel = mode
        }
    }

    private func writeFieldByRegistry(_ fieldId: String, value: String) {
        let registry = services.pluginManager.additionalConnectionFields(for: network.type)
        guard let field = registry.first(where: { $0.id == fieldId }) else {
            advanced.additionalFieldValues[fieldId] = value
            return
        }
        switch field.section {
        case .authentication:
            auth.additionalFieldValues[fieldId] = value
        case .connection:
            network.additionalFieldValues[fieldId] = value
        case .advanced:
            advanced.additionalFieldValues[fieldId] = value
        }
    }

    // MARK: - Clipboard

    func detectClipboardConnectionStringIfNeeded(
        connectionStorage: ConnectionStorage = .shared,
        pasteboard: NSPasteboard = .general
    ) {
        guard isNew, !clipboardBannerDismissed, clipboardCandidate == nil else { return }
        guard let raw = pasteboard.string(forType: .string) else { return }
        let firstLine = raw
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !firstLine.isEmpty else { return }

        let parsed: ParsedConnection
        do {
            parsed = try ConnectionStringParser.parse(firstLine)
        } catch {
            return
        }

        if matchesExistingConnection(parsed: parsed, connectionStorage: connectionStorage) {
            return
        }

        clipboardCandidate = parsed
    }

    func applyClipboardCandidate(_ parsed: ParsedConnection) {
        let oldType = network.type
        network.type = parsed.type
        if oldType != parsed.type {
            applyTypeDefaults(parsed.type, includeNetwork: false)
            auth.resetForType(parsed.type)
            advanced.resetForType(parsed.type)
        }

        network.host = parsed.host
        if parsed.port > 0 {
            network.port = String(parsed.port)
        } else {
            network.port = String(parsed.type.defaultPort)
        }
        auth.username = parsed.username ?? ""
        auth.password = parsed.password ?? ""
        network.database = parsed.database ?? ""
        auth.promptForPassword = false

        if network.name.isEmpty {
            let suggestion = parsed.database.map { "\(parsed.type.rawValue) \(parsed.host)/\($0)" }
                ?? "\(parsed.type.rawValue) \(parsed.host)"
            network.name = suggestion
        }

        if parsed.useSSL {
            ssl.upgradeIfDisabled(to: .required)
        }

        if parsed.type == .mongodb {
            if let authSource = parsed.queryParameters["authSource"], !authSource.isEmpty {
                writeFieldByRegistry("mongoAuthSource", value: authSource)
            }
            if parsed.rawScheme == "mongodb+srv" {
                writeFieldByRegistry("mongoUseSrv", value: "true")
            }
        }

        clipboardCandidate = nil
    }

    func dismissClipboardCandidate() {
        clipboardCandidate = nil
        clipboardBannerDismissed = true
    }

    private func matchesExistingConnection(
        parsed: ParsedConnection,
        connectionStorage: ConnectionStorage
    ) -> Bool {
        connectionStorage.loadConnections().contains { saved in
            saved.host == parsed.host
                && saved.port == parsed.port
                && saved.username == (parsed.username ?? "")
        }
    }

    // MARK: - Mongo helpers

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
        if parts.count > 1, let portValue = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
            port = portValue
        }
        return NormalizedHosts(hosts: normalized, primaryHost: host, primaryPort: port)
    }
}
