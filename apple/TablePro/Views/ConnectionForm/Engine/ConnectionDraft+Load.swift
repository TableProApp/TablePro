//
//  ConnectionDraft+Load.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary
import TableProPluginKit
import TableProRedisCore
import TableProSSHConfig

extension ConnectionDraft {
    // Every section's plugin defaults are seeded here, once, for a new connection.
    static func new(type: DatabaseType, traits: ConnectionTypeTraits) -> ConnectionDraft {
        var draft = ConnectionDraft(type: type)
        draft.host = traits.defaultHost ?? ""
        draft.portText = traits.defaultPortText
        draft.fieldValues = traits.defaultValues()
        if let hostList = traits.fields.endpointHostList, draft.fieldValues[hostList.id] == nil {
            draft.fieldValues[hostList.id] = HostListEndpoint.parse(draft.host, defaultPort: traits.defaultPort)?.entry
        }
        draft.ssl.mode = traits.ssl.defaultMode
        draft.ssl.origin = .typeDefault
        return draft
    }

    static func loaded(
        from connection: DatabaseConnection,
        secrets: DraftSecrets,
        traits: ConnectionTypeTraits,
        sshConfigEntries: [SSHConfigEntry] = []
    ) -> ConnectionDraft {
        var draft = ConnectionDraft(type: connection.type)
        let fields = connection.additionalFields
        draft.name = connection.name
        draft.environment = fields[ConnectionEnvironment.fieldKey].flatMap(ConnectionEnvironment.init(rawValue:)) ?? .none
        draft.host = connection.host
        draft.portText = connection.port > 0 ? String(connection.port) : ""
        draft.database = connection.database
        if traits.socketForwardApplies {
            draft.sshForwardUnixSocketPath = fields[DatabaseConnection.sshForwardUnixSocketPathKey] ?? ""
        }

        draft.fieldValues = loadedFieldValues(from: connection, secrets: secrets, traits: traits)

        draft.credentials.mode = connection.credentialMode
        draft.credentials.username = connection.username
        draft.credentials.password = secrets.password ?? ""
        draft.credentials.storedPasswordState = secrets.passwordState
        draft.credentials.promptsForPassword = connection.promptForPassword
        draft.credentials.passwordSource = connection.passwordSource

        draft.loadTransports(from: connection, secrets: secrets, traits: traits, sshConfigEntries: sshConfigEntries)

        draft.ssl.mode = connection.sslConfig.mode
        draft.ssl.origin = connection.sslConfig.mode == traits.ssl.defaultMode ? .typeDefault : .chosen
        draft.ssl.caCertPath = connection.sslConfig.caCertificatePath
        draft.ssl.clientCertPath = connection.sslConfig.clientCertificatePath
        draft.ssl.clientKeyPath = connection.sslConfig.clientKeyPath
        draft.ssl.clientKeyPassphrase = secrets.sslClientKeyPassphrase ?? ""

        draft.options.connectTimeoutSeconds = connection.connectTimeoutSeconds
        draft.options.queryTimeoutSeconds = connection.queryTimeoutSeconds
        draft.options.binaryInlineLimitKilobytes = connection.binaryInlineLimitKilobytes
        draft.options.completionIdentifierCase = connection.completionIdentifierCase
        draft.options.startupCommands = connection.startupCommands ?? ""
        draft.options.preConnectScript = connection.preConnectScript ?? ""
        draft.options.postDisconnectScript = connection.postDisconnectScript ?? ""
        draft.options.scriptTimeoutSeconds = connection.scriptTimeoutSeconds
        draft.options.localOnly = connection.localOnly

        draft.safety.safeModeLevel = connection.preferredSafeModeLevel
        draft.safety.userSetSafeMode = true
        draft.safety.commitMode = connection.commitMode
        draft.safety.maskingRules = connection.maskingRules

        draft.ai.policy = connection.aiPolicy
        draft.ai.rules = connection.aiRules ?? ""
        draft.ai.externalAccess = connection.externalAccess
        draft.ai.alwaysAllowedTools = connection.aiAlwaysAllowedTools.sorted()

        draft.appearance.color = connection.color
        draft.appearance.iconName = LibrarySymbolCatalog.normalizedName(connection.iconName)
        draft.appearance.tagIds = connection.tagIds
        draft.appearance.groupId = connection.groupId

        return ConnectionEditorEngine.normalized(draft, traits)
    }

    // Declared fields only: undeclared keys stay in the record and the merge keeps them.
    private static func loadedFieldValues(
        from connection: DatabaseConnection,
        secrets: DraftSecrets,
        traits: ConnectionTypeTraits
    ) -> [String: String] {
        let stored = connection.additionalFields
        var values: [String: String] = [:]
        for field in traits.fields {
            if field.isSecure {
                values[field.id] = secrets.pluginSecureFields[field.id] ?? ""
            } else if let value = stored[field.id] {
                values[field.id] = value
            } else if let defaultValue = field.defaultValue {
                values[field.id] = defaultValue
            }
        }
        if let sessionToken = secrets.pluginSecureFields[ConnectionSecretOptions.mongoSessionTokenFieldId] {
            values[ConnectionSecretOptions.mongoSessionTokenFieldId] = sessionToken
        }
        if traits.field(RedisDatabaseIndex.fieldName) != nil {
            values[RedisDatabaseIndex.fieldName] = String(connection.configuredRedisDatabaseIndex)
        }
        // A file-backed driver with its own path field reads `database` when the field is empty.
        if case .additionalField(let pathFieldId) = traits.localFilePathField,
           (values[pathFieldId] ?? "").isEmpty,
           !connection.database.isEmpty {
            values[pathFieldId] = connection.database
        }
        if let hostList = traits.fields.endpointHostList {
            values[hostList.id] = ConnectionEditorEngine.endpointList(
                values[hostList.id] ?? "",
                host: connection.host,
                port: connection.port,
                traits: traits
            )
        }
        return values
    }

    private mutating func loadTransports(
        from connection: DatabaseConnection,
        secrets: DraftSecrets,
        traits: ConnectionTypeTraits,
        sshConfigEntries: [SSHConfigEntry]
    ) {
        var sshEnabled = false
        switch connection.sshTunnelMode {
        case .disabled:
            break
        case .inline(let config):
            sshEnabled = true
            ssh.populateFields(from: config, configEntries: sshConfigEntries)
            ssh.remoteFilePath = config.remoteFilePath
            ssh.remoteFileAccess = config.remoteFileAccess
        case .profile(let id, let snapshot):
            sshEnabled = true
            ssh.profileId = id
            ssh.profileSnapshot = snapshot
            ssh.populateFields(from: snapshot, configEntries: sshConfigEntries)
            ssh.remoteFilePath = connection.sshConfig.remoteFilePath
            ssh.remoteFileAccess = connection.sshConfig.remoteFileAccess
        }
        ssh.password = secrets.sshPassword ?? ""
        ssh.keyPassphrase = secrets.sshKeyPassphrase ?? ""
        ssh.totpSecret = secrets.totpSecret ?? ""
        ssh.storedPasswordState = secrets.sshPasswordState
        ssh.storedKeyPassphraseState = secrets.sshKeyPassphraseState

        var cloudflareEnabled = false
        if case .inline(let config) = connection.cloudflareTunnelMode {
            cloudflareEnabled = true
            cloudflare.populateFields(from: config)
        }
        cloudflare.serviceTokenId = secrets.cloudflareTokenId ?? ""
        cloudflare.serviceTokenSecret = secrets.cloudflareTokenSecret ?? ""

        var cloudSQLEnabled = false
        if case .inline(let config) = connection.cloudSQLProxyMode {
            cloudSQLEnabled = true
            cloudSQLProxy.populateFields(from: config)
        }
        cloudSQLProxy.serviceAccountKeyJSON = secrets.cloudSQLServiceAccountKey ?? ""

        var socksEnabled = false
        if case .inline(let config) = connection.socksProxyMode {
            socksEnabled = true
            socksProxy.host = config.host
            socksProxy.port = String(config.port)
            socksProxy.username = config.username
        }
        socksProxy.password = secrets.socksPassword ?? ""

        var tunnelCommandEnabled = false
        if case .inline(let config) = connection.tunnelCommandMode {
            tunnelCommandEnabled = true
            tunnelCommand.config = config
        }

        // An older build could store two transports; the first one wins, as the connect path reads it.
        if sshEnabled {
            transport = traits.supportsRemoteDatabaseFile ? .remoteFile : .ssh
        } else if cloudflareEnabled {
            transport = .cloudflare
        } else if cloudSQLEnabled {
            transport = .cloudSQLProxy
        } else if socksEnabled {
            transport = .socksProxy
        } else if tunnelCommandEnabled {
            transport = .tunnelCommand
        }

        let socketPath = MySQLLocalSocket.path(in: connection.additionalFields)
        if traits.supportsLocalSocket, transport == nil, let socketPath {
            endpoint = .localSocket
            localSocketPath = socketPath
        }
    }
}
