//
//  ConnectionFormCoordinator.swift
//  TablePro
//

import AppKit
import Combine
import os
import SwiftUI
import TableProPluginKit
import TableProSyncTransport

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
    var cloudflareTunnel: CloudflareTunnelPaneViewModel
    var cloudSQLProxy: CloudSQLProxyPaneViewModel
    var socksProxy: SOCKSProxyPaneViewModel
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
        if services.pluginManager.supportsCloudflareTunnel(for: network.type) {
            panes.append(.cloudflareTunnel)
        }
        if network.type.supportsCloudSQLProxy {
            panes.append(.cloudSQLProxy)
        }
        if services.pluginManager.supportsSOCKSProxy(for: network.type) {
            panes.append(.socksProxy)
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
            && cloudflareTunnel.validationIssues.isEmpty
            && cloudSQLProxy.validationIssues.isEmpty
            && socksProxy.validationIssues.isEmpty
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
        self.cloudflareTunnel = CloudflareTunnelPaneViewModel()
        self.cloudSQLProxy = CloudSQLProxyPaneViewModel()
        self.socksProxy = SOCKSProxyPaneViewModel()
        self.ssl = SSLPaneViewModel()
        self.customization = CustomizationPaneViewModel()
        self.advanced = AdvancedPaneViewModel()
        self.aiRules = AIRulesPaneViewModel()

        let ref = WeakCoordinatorRef(self)
        network.coordinator = ref
        auth.coordinator = ref
        ssh.coordinator = ref
        cloudflareTunnel.coordinator = ref
        cloudSQLProxy.coordinator = ref
        socksProxy.coordinator = ref
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
            cloudflareTunnel.load(from: existing, storage: storage)
            cloudSQLProxy.load(from: existing, storage: storage)
            socksProxy.load(from: existing, storage: storage)
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
        services.appEvents.connectionUpdated.send(connection.id)
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
        ssl.resetForType(newType)
    }

    // MARK: - Save

    func save() {
        saveConnection(connect: false)
    }

    func saveAndConnect() {
        saveConnection(connect: isNew)
    }

    func buildEdits() -> ConnectionFormEdits {
        var fields: [String: String] = [:]
        network.write(into: &fields)
        auth.write(into: &fields)
        advanced.write(into: &fields)

        var resolvedHost = network.resolvedHost
        var resolvedPort = network.resolvedPort

        if network.type.pluginTypeId == "MongoDB",
           let mongoHosts = fields["mongoHosts"],
           !mongoHosts.isEmpty
        {
            let result = Self.normalizeMongoHosts(mongoHosts, defaultPort: network.type.defaultPort)
            fields["mongoHosts"] = result.hosts
            resolvedHost = result.primaryHost
            resolvedPort = result.primaryPort
        }

        let trimmedScript = advanced.preConnectScript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedScript.isEmpty {
            fields.removeValue(forKey: "preConnectScript")
        } else {
            fields["preConnectScript"] = advanced.preConnectScript
        }

        return ConnectionFormEdits(
            name: network.name,
            host: resolvedHost,
            port: resolvedPort,
            database: network.database,
            username: auth.resolvedUsername,
            type: network.type,
            sshConfig: ssh.state.buildSSHConfig(),
            sslConfig: ssl.buildConfig(),
            color: customization.color,
            tagIds: customization.tagIds,
            groupId: customization.groupId,
            sshProfileId: ssh.state.enabled ? ssh.state.profileId : nil,
            sshTunnelMode: ssh.state.buildTunnelMode(),
            cloudflareTunnelMode: cloudflareTunnel.state.buildTunnelMode(),
            cloudSQLProxyMode: cloudSQLProxy.state.buildTunnelMode(),
            socksProxyMode: socksProxy.state.buildTunnelMode(),
            safeModeLevel: customization.safeModeLevel,
            aiPolicy: advanced.aiPolicy,
            aiRules: aiRules.trimmedRules,
            externalAccess: advanced.externalAccess,
            redisDatabase: advanced.additionalFieldValues["redisDatabase"].map { Int($0) ?? 0 },
            startupCommands: advanced.startupCommands.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : advanced.startupCommands,
            localOnly: advanced.localOnly,
            additionalFields: fields,
            ownedAdditionalFieldIDs: ownedAdditionalFieldIDs()
        )
    }

    private func ownedAdditionalFieldIDs() -> Set<String> {
        var ids = ConnectionFormEdits.appManagedAdditionalFieldIDs
        for field in services.pluginManager.additionalConnectionFields(for: network.type) {
            ids.insert(field.id)
        }
        guard let originalType = originalConnection?.type, originalType != network.type else {
            return ids
        }
        for field in services.pluginManager.additionalConnectionFields(for: originalType) {
            ids.insert(field.id)
        }
        return ids
    }

    private func baseConnection(id: UUID) -> DatabaseConnection {
        guard let original = originalConnection, original.id == id else {
            return DatabaseConnection(id: id, name: "")
        }
        return original
    }

    private func saveConnection(connect: Bool) {
        let finalId = connectionId ?? UUID()

        var edits = buildEdits()
        edits.additionalFields["promptForPassword"] = auth.effectivePromptForPassword ? "true" : nil

        let secureFields = services.pluginManager.additionalConnectionFields(for: network.type)
            .filter(\.isSecure)
        for field in secureFields {
            if let value = edits.additionalFields[field.id], !value.isEmpty {
                storage.savePluginSecureField(value, fieldId: field.id, for: finalId)
            } else {
                storage.deletePluginSecureField(fieldId: field.id, for: finalId)
            }
            edits.additionalFields.removeValue(forKey: field.id)
        }

        let connectionToSave = edits.applied(to: baseConnection(id: finalId))

        if auth.effectivePromptForPassword {
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

        if !ssl.clientKeyPassphrase.isEmpty && !ssl.clientKeyPath.trimmingCharacters(in: .whitespaces).isEmpty {
            storage.saveSSLClientKeyPassphrase(ssl.clientKeyPassphrase, for: connectionToSave.id)
        } else {
            storage.deleteSSLClientKeyPassphrase(for: connectionToSave.id)
        }

        cloudflareTunnel.save(to: connectionToSave.id, storage: storage)
        cloudSQLProxy.save(to: connectionToSave.id, storage: storage)
        socksProxy.save(to: connectionToSave.id, storage: storage)

        var savedConnections = storage.loadConnections()
        if isNew {
            savedConnections.append(connectionToSave)
            guard storage.saveConnections(savedConnections) else {
                saveError = String(localized: "Could not save the connection. Check disk space and permissions, then try again.")
                return
            }
            if !connectionToSave.localOnly {
                services.syncTracker.markDirty(.connection, id: connectionToSave.id.uuidString)
            }
            dismissAction?()
            services.appEvents.connectionUpdated.send(connectionToSave.id)
            if connect {
                connectToDatabase(connectionToSave)
            }
        } else {
            guard let index = savedConnections.firstIndex(where: { $0.id == connectionToSave.id }) else {
                saveError = String(localized: "This connection was deleted on another device or window. Your changes were not saved.")
                return
            }
            savedConnections[index] = connectionToSave
            guard storage.saveConnections(savedConnections) else {
                saveError = String(localized: "Could not save the connection. Check disk space and permissions, then try again.")
                return
            }
            if !connectionToSave.localOnly {
                services.syncTracker.markDirty(.connection, id: connectionToSave.id.uuidString)
            }
            dismissAction?()
            services.appEvents.connectionUpdated.send(connectionToSave.id)
        }
    }

    func connectToDatabase(_ connection: DatabaseConnection) {
        Task {
            do {
                try await TabRouter.shared.route(.openConnection(connection.id))
            } catch {
                handleConnectError(error, connection: connection)
            }
        }
    }

    func handleConnectError(_ error: Error, connection: DatabaseConnection) {
        if error is CancellationError {
            Self.logger.info("Connection attempt cancelled for \(connection.name, privacy: .public)")
            return
        }

        if !WindowManager.shared.hasOpenWindow(for: connection.id) {
            Self.logger.info(
                "Connection failed after window was closed: \(error.localizedDescription, privacy: .public)")
            return
        }

        WindowManager.shared.closeWindow(for: connection.id)

        if case PluginError.pluginNotInstalled = error {
            Self.logger.info("Plugin not installed for \(connection.type.rawValue, privacy: .public)")
            WelcomeRouter.shared.routePluginInstall(connection)
            return
        }

        Self.logger.error("Failed to connect: \(error.localizedDescription, privacy: .public)")
        WelcomeRouter.shared.routeError(error, for: connection)
    }

    func connectAfterInstall(_ connection: DatabaseConnection) {
        Task {
            do {
                try await TabRouter.shared.route(.openConnection(connection.id))
            } catch {
                handleConnectError(error, connection: connection)
            }
        }
    }

    // MARK: - Test

    func test() {
        guard testTask == nil else { return }
        isTesting = true
        testSucceeded = false
        let window = NSApp.keyWindow

        var testConn = buildEdits().applied(to: DatabaseConnection(id: UUID(), name: ""))
        testConn.passwordSource = auth.password.isEmpty ? originalConnection?.passwordSource : nil
        temporaryTestIds.insert(testConn.id)

        let password = auth.password
        let promptForPassword = auth.effectivePromptForPassword
        let connectionType = network.type
        let displayName = network.name.isEmpty ? network.host : network.name
        let sshState = ssh.state
        let tunnelStates = TunnelFormStates(
            ssh: ssh.state,
            cloudflare: cloudflareTunnel.state,
            cloudSQLProxy: cloudSQLProxy.state,
            socksProxy: socksProxy.state
        )
        let sslClientKeyPassphrase = ssl.clientKeyPassphrase
        let sslClientKeyPath = ssl.clientKeyPath
        let additionalFieldValues = testConn.additionalFields

        persistTestSecrets(
            for: testConn.id,
            password: password,
            promptForPassword: promptForPassword,
            tunnelStates: tunnelStates,
            sslClientKeyPassphrase: sslClientKeyPassphrase,
            sslClientKeyPath: sslClientKeyPath,
            connectionType: connectionType,
            additionalFieldValues: additionalFieldValues
        )

        testTask = Task { [weak self] in
            do {
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
                let fields = self?.auth.additionalFieldValues ?? [:]
                if let provider = ConnectionSignInRegistry.provider(for: error, fields: fields) {
                    await self?.offerSignIn(provider, fields: fields, testId: testConn.id, window: window)
                    return
                }
                await MainActor.run {
                    self?.cleanupTestSecrets(for: testConn.id)
                    self?.isTesting = false
                    self?.testSucceeded = false
                    self?.testTask = nil
                    if case PluginError.pluginNotInstalled = error {
                        self?.pluginInstallConnection = testConn
                    } else if let item = PluginDiagnosticItem.classify(
                        error: error, connection: testConn, username: testConn.username
                    ) {
                        self?.pluginDiagnostic = item
                    } else {
                        AlertHelper.showErrorSheet(
                            title: String(localized: "Connection Test Failed"),
                            message: SSLHandshakeError.formatted(error),
                            window: window
                        )
                    }
                }
            }
        }
    }

    /// Testing tears down first so the sheet never covers a running test, and the result is left
    /// alone rather than marked failed: the credential was the problem, not the settings.
    private func offerSignIn(
        _ provider: ConnectionSignInProvider,
        fields: [String: String],
        testId: UUID,
        window: NSWindow?
    ) async {
        cleanupTestSecrets(for: testId)
        isTesting = false
        testTask = nil
        guard await ConnectionSignInPrompt.offer(provider, fields: fields, window: window) else { return }
        AlertHelper.showInfoSheet(
            title: String(localized: "Signed In"),
            message: provider.signedInMessage,
            window: window
        )
    }

    private struct TunnelFormStates {
        let ssh: SSHTunnelFormState
        let cloudflare: CloudflareTunnelFormState
        let cloudSQLProxy: CloudSQLProxyFormState
        let socksProxy: SOCKSProxyFormState
    }

    private func persistTestSecrets(
        for testId: UUID,
        password: String,
        promptForPassword: Bool,
        tunnelStates: TunnelFormStates,
        sslClientKeyPassphrase: String,
        sslClientKeyPath: String,
        connectionType: DatabaseType,
        additionalFieldValues: [String: String]
    ) {
        let sshState = tunnelStates.ssh
        let cloudflareState = tunnelStates.cloudflare
        let cloudSQLProxyState = tunnelStates.cloudSQLProxy
        let socksProxyState = tunnelStates.socksProxy

        if !password.isEmpty && !promptForPassword {
            services.connectionStorage.savePassword(password, for: testId)
        }
        if sshState.enabled && sshState.profileId == nil {
            if (sshState.authMethod == .password || sshState.authMethod == .keyboardInteractive)
                && !sshState.password.isEmpty
            {
                services.connectionStorage.saveSSHPassword(sshState.password, for: testId)
            }
            if sshState.authMethod == .privateKey && !sshState.keyPassphrase.isEmpty {
                services.connectionStorage.saveKeyPassphrase(sshState.keyPassphrase, for: testId)
            }
            if sshState.totpMode == .autoGenerate && !sshState.totpSecret.isEmpty {
                services.connectionStorage.saveTOTPSecret(sshState.totpSecret, for: testId)
            }
        }

        if !sslClientKeyPassphrase.isEmpty
            && !sslClientKeyPath.trimmingCharacters(in: .whitespaces).isEmpty
        {
            services.connectionStorage.saveSSLClientKeyPassphrase(sslClientKeyPassphrase, for: testId)
        }

        if cloudflareState.enabled && cloudflareState.authMethod == .serviceToken {
            services.connectionStorage.saveCloudflareTokenId(cloudflareState.serviceTokenId, for: testId)
            services.connectionStorage.saveCloudflareTokenSecret(cloudflareState.serviceTokenSecret, for: testId)
        }

        if cloudSQLProxyState.enabled && cloudSQLProxyState.authMode == .serviceAccountKey
            && !cloudSQLProxyState.serviceAccountKeyJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            services.connectionStorage.saveCloudSQLProxyServiceAccountKey(
                cloudSQLProxyState.serviceAccountKeyJSON, for: testId
            )
        }

        if socksProxyState.enabled && !socksProxyState.password.isEmpty {
            services.connectionStorage.saveSOCKSProxyPassword(socksProxyState.password, for: testId)
        }

        for field in services.pluginManager.additionalConnectionFields(for: connectionType)
            where field.isSecure
        {
            if let value = additionalFieldValues[field.id], !value.isEmpty {
                services.connectionStorage.savePluginSecureField(value, fieldId: field.id, for: testId)
            }
        }
    }

    func cleanupTestSecrets(for testId: UUID) {
        services.connectionStorage.deletePassword(for: testId)
        services.connectionStorage.deleteSSHPassword(for: testId)
        services.connectionStorage.deleteKeyPassphrase(for: testId)
        services.connectionStorage.deleteSSLClientKeyPassphrase(for: testId)
        services.connectionStorage.deleteTOTPSecret(for: testId)
        services.connectionStorage.deleteCloudflareTokenId(for: testId)
        services.connectionStorage.deleteCloudflareTokenSecret(for: testId)
        services.connectionStorage.deleteCloudSQLProxyServiceAccountKey(for: testId)
        services.connectionStorage.deleteSOCKSProxyPassword(for: testId)
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

    /// Every additional field value the form currently holds, across all three panes.
    ///
    /// The panes each own the values for their own section, so a `visibleWhen` rule that points at
    /// a field in another section can never see it from inside one pane. Redis needs exactly that:
    /// the Sentinel credentials live under Authentication and appear only when the Connection
    /// Mode field, which lives under Connection, says sentinel.
    var allAdditionalFieldValues: [String: String] {
        auth.additionalFieldValues
            .merging(network.additionalFieldValues) { _, network in network }
            .merging(advanced.additionalFieldValues) { _, advanced in advanced }
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
        ssl.mode = parsed.sslMode ?? parsed.type.defaultSSLMode

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
            if parsed.sshNoAuth == true {
                ssh.state.authMethod = .none
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
            case "uuidRepresentation":
                writeFieldByRegistry("mongoUuidRepresentation", value: value)
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
        if let env = parsed.envTag, !env.isEmpty,
           let resolved = ConnectionURLParser.tagId(fromEnvName: env),
           !customization.tagIds.contains(resolved) {
            customization.tagIds.append(resolved)
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
        if parsed.type.pluginTypeId == "DuckDB" {
            if parsed.host.isEmpty {
                writeFieldByRegistry("duckdbMode", value: "local")
                writeFieldByRegistry("duckdbFilePath", value: parsed.database)
            } else {
                writeFieldByRegistry("duckdbMode", value: "remote")
                writeFieldByRegistry("duckdbHost", value: parsed.host)
                if let port = parsed.port {
                    writeFieldByRegistry("duckdbPort", value: String(port))
                }
                if !parsed.database.isEmpty {
                    writeFieldByRegistry("duckdbAlias", value: parsed.database)
                }
            }
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
            ssl.mode = .required
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
