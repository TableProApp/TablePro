//
//  ConnectionEditorEngine+Edits.swift
//  TablePro
//

import Foundation
import TableProAutocomplete
import TableProConnectionLibrary
import TableProPluginKit
import TableProRedisCore
import TableProSSHConfig

extension ConnectionEditorEngine {
    // Secure values never reach the record: every secure id either type could hold, and the Mongo session token.
    static func secretFieldIds(_ traits: ConnectionTypeTraits, originalTraits: ConnectionTypeTraits?) -> Set<String> {
        var ids = Set(traits.declaredSecureFieldIds + traits.storedSecureFieldIds)
        if let originalTraits {
            ids.formUnion(originalTraits.declaredSecureFieldIds + originalTraits.storedSecureFieldIds)
        }
        ids.insert(ConnectionSecretOptions.mongoSessionTokenFieldId)
        return ids
    }

    static func ownedAdditionalFieldIds(_ traits: ConnectionTypeTraits, originalTraits: ConnectionTypeTraits?) -> Set<String> {
        var ids = ConnectionFormEdits.appManagedAdditionalFieldIDs
        ids.formUnion(traits.fields.map(\.id))
        if let originalTraits, originalTraits.type != traits.type {
            ids.formUnion(originalTraits.fields.map(\.id))
        }
        return ids
    }

    static func edits(
        _ draft: ConnectionDraft,
        _ traits: ConnectionTypeTraits,
        originalTraits: ConnectionTypeTraits?,
        _ context: EditorContext
    ) -> ConnectionFormEdits {
        let draft = normalized(draft, traits)
        let secretIds = secretFieldIds(traits, originalTraits: originalTraits)
        var fields = draft.fieldValues.filter { !secretIds.contains($0.key) }

        let forwardSocket = draft.sshForwardUnixSocketPath.trimmingCharacters(in: .whitespaces)
        if draft.transport == .ssh, !forwardSocket.isEmpty {
            fields[DatabaseConnection.sshForwardUnixSocketPathKey] = forwardSocket
        }
        let socket = localSocketEndpoint(draft, traits)
        if let socket {
            fields[MySQLLocalSocket.fieldKey] = socket.path
        }

        var host = resolvedHost(draft, traits)
        var port = socket?.port ?? resolvedPort(draft, traits)
        // An empty list means what its placeholder shows, never the Host it hid.
        if let hostList = traits.fields.endpointHostList {
            let endpoints = HostListEndpoint.parseList(fields[hostList.id] ?? "", defaultPort: traits.defaultPort)
            fields[hostList.id] = endpoints.map(\.entry).joined(separator: ",")
            let primary = endpoints.first
                ?? HostListEndpoint(host: traits.defaultHost ?? "localhost", port: traits.defaultPort)
            host = primary.host
            port = primary.port
        }

        writeScripts(draft, into: &fields)
        fields[ConnectionEnvironment.fieldKey] = draft.environment == .none ? nil : draft.environment.rawValue
        fields["promptForPassword"] = effectivePromptForPassword(draft, traits) ? "true" : nil

        let ssh = sshValues(draft, context)
        return ConnectionFormEdits(
            name: draft.name,
            host: host,
            port: port,
            database: draft.database,
            username: context.credentialProfile(draft.credentials.mode.profileId)?.username
                ?? draft.credentials.username.trimmingCharacters(in: .whitespaces),
            type: draft.type,
            sshConfig: ssh.config,
            sslConfig: draft.ssl.configuration,
            color: draft.appearance.color,
            iconName: draft.appearance.iconName,
            tagIds: draft.appearance.tagIds,
            groupId: draft.appearance.groupId,
            sshProfileId: ssh.profileId,
            sshTunnelMode: ssh.mode,
            credentialMode: draft.credentials.mode,
            cloudflareTunnelMode: draft.transport == .cloudflare ? .inline(draft.cloudflare.configuration) : .disabled,
            cloudSQLProxyMode: draft.transport == .cloudSQLProxy ? .inline(draft.cloudSQLProxy.configuration) : .disabled,
            socksProxyMode: draft.transport == .socksProxy ? .inline(draft.socksProxy.configuration) : .disabled,
            tunnelCommandMode: draft.transport == .tunnelCommand
                ? .inline(draft.tunnelCommand.trimmedConfiguration) : .disabled,
            safeModeLevel: draft.safety.safeModeLevel,
            aiPolicy: draft.ai.policy,
            aiRules: draft.ai.rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draft.ai.rules,
            externalAccess: draft.ai.externalAccess,
            connectTimeoutSeconds: draft.options.connectTimeoutSeconds,
            queryTimeoutSeconds: draft.options.queryTimeoutSeconds,
            binaryInlineLimitKilobytes: draft.options.binaryInlineLimitKilobytes,
            completionIdentifierCase: draft.options.completionIdentifierCase,
            commitMode: draft.safety.commitMode,
            redisDatabase: traits.field(RedisDatabaseIndex.fieldName) == nil
                ? nil
                : draft.fieldValues[RedisDatabaseIndex.fieldName].map { RedisDatabaseIndex.parse($0) ?? 0 },
            startupCommands: draft.options.startupCommands.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : draft.options.startupCommands,
            localOnly: draft.options.localOnly,
            additionalFields: fields,
            ownedAdditionalFieldIDs: ownedAdditionalFieldIds(traits, originalTraits: originalTraits),
            maskingRules: draft.safety.maskingRules.filter { !$0.trimmedPattern.isEmpty },
            revokedAIAlwaysAllowedTools: draft.ai.revokedTools
        )
    }

    private static func writeScripts(_ draft: ConnectionDraft, into fields: inout [String: String]) {
        for (key, script) in [
            ("preConnectScript", draft.options.preConnectScript),
            (DatabaseConnection.postDisconnectScriptKey, draft.options.postDisconnectScript)
        ] {
            fields[key] = script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : script
        }
        if let timeout = draft.options.scriptTimeoutSeconds, ConnectionScriptRunner.timeoutSecondsRange.contains(timeout) {
            fields[DatabaseConnection.scriptTimeoutSecondsKey] = String(timeout)
        } else {
            fields[DatabaseConnection.scriptTimeoutSecondsKey] = nil
        }
    }

    // A profile names a server, not a file, so the remote path overlays whichever configuration is in play.
    private static func sshValues(
        _ draft: ConnectionDraft,
        _ context: EditorContext
    ) -> (config: SSHConfiguration, profileId: UUID?, mode: SSHTunnelMode) {
        func overlaid(_ config: SSHConfiguration) -> SSHConfiguration {
            var config = config
            config.enabled = true
            config.remoteFilePath = draft.ssh.remoteFilePath
            config.remoteFileAccess = draft.ssh.remoteFileAccess
            return config
        }
        switch sshResolution(draft, context) {
        case .disabled:
            return (draft.ssh.inlineConfiguration(enabled: false), nil, .disabled)
        case .inline(let config):
            return (config, nil, .inline(config))
        case .profile(let profile):
            let config = overlaid(profile.toSSHConfiguration())
            return (config, profile.id, .profile(id: profile.id, snapshot: config))
        case .unresolvedProfile(let id, let snapshot):
            let config = overlaid(snapshot)
            return (config, id, .profile(id: id, snapshot: config))
        }
    }

    // What a test result was earned on. Name, appearance and policy edits leave a result standing.
    struct TestFingerprint: Equatable {
        let edits: ConnectionFormEdits
        let secrets: [String]
    }

    static func testFingerprint(
        _ draft: ConnectionDraft,
        _ traits: ConnectionTypeTraits,
        originalTraits: ConnectionTypeTraits?,
        _ context: EditorContext
    ) -> TestFingerprint {
        var edits = edits(draft, traits, originalTraits: originalTraits, context)
        edits.name = ""
        edits.color = .none
        edits.iconName = nil
        edits.tagIds = []
        edits.groupId = nil
        edits.safeModeLevel = .silent
        edits.aiPolicy = nil
        edits.aiRules = nil
        edits.externalAccess = .readOnly
        edits.maskingRules = []
        edits.revokedAIAlwaysAllowedTools = []
        edits.localOnly = false
        edits.completionIdentifierCase = .default
        edits.commitMode = .automatic
        edits.binaryInlineLimitKilobytes = nil
        edits.queryTimeoutSeconds = nil
        edits.additionalFields[ConnectionEnvironment.fieldKey] = nil
        let secretIds = secretFieldIds(traits, originalTraits: originalTraits)
        let pluginSecrets = draft.fieldValues
            .filter { secretIds.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        let secrets = [
            draft.credentials.password,
            draft.ssh.password,
            draft.ssh.keyPassphrase,
            draft.ssh.totpSecret,
            draft.ssl.clientKeyPassphrase,
            draft.cloudflare.serviceTokenId,
            draft.cloudflare.serviceTokenSecret,
            draft.cloudSQLProxy.serviceAccountKeyJSON,
            draft.socksProxy.password
        ] + pluginSecrets
        return TestFingerprint(edits: edits, secrets: secrets)
    }

    // A test record carries what the saved one would, under a throwaway id.
    static func record(_ connection: DatabaseConnection, reassignedTo id: UUID) -> DatabaseConnection {
        var copy = DatabaseConnection(
            id: id,
            name: connection.name,
            host: connection.host,
            port: connection.port,
            database: connection.database,
            username: connection.username,
            type: connection.type,
            sshConfig: connection.sshConfig,
            sslConfig: connection.sslConfig,
            color: connection.color,
            iconName: connection.iconName,
            tagIds: connection.tagIds,
            groupId: connection.groupId,
            sshProfileId: connection.sshProfileId,
            sshTunnelMode: connection.sshTunnelMode,
            credentialMode: connection.credentialMode,
            cloudflareTunnelMode: connection.cloudflareTunnelMode,
            cloudSQLProxyMode: connection.cloudSQLProxyMode,
            socksProxyMode: connection.socksProxyMode,
            tunnelCommandMode: connection.tunnelCommandMode,
            safeModeLevel: connection.preferredSafeModeLevel,
            aiPolicy: connection.aiPolicy,
            aiRules: connection.aiRules,
            aiAlwaysAllowedTools: connection.aiAlwaysAllowedTools,
            externalAccess: connection.externalAccess,
            redisDatabase: connection.redisDatabase,
            startupCommands: connection.startupCommands,
            sortOrder: connection.sortOrder,
            localOnly: connection.localOnly,
            isSample: connection.isSample,
            isFavorite: connection.isFavorite,
            passwordSource: connection.passwordSource,
            additionalFields: connection.additionalFields
        )
        copy.sshRoute = connection.sshRoute
        copy.origin = connection.origin
        return copy
    }
}
