//
//  ConnectionFormEdits.swift
//  TablePro
//

import Foundation
import TableProAutocomplete
import TableProSSHConfig

struct ConnectionFormEdits: Equatable {
    var name: String
    var host: String
    var port: Int
    var database: String
    var username: String
    var type: DatabaseType
    var sshConfig: SSHConfiguration
    var sslConfig: SSLConfiguration
    var color: ConnectionColor
    var iconName: String?
    var tagIds: [UUID]
    var groupId: UUID?
    var sshProfileId: UUID?
    var sshTunnelMode: SSHTunnelMode
    var credentialMode: CredentialMode
    var cloudflareTunnelMode: CloudflareTunnelMode
    var cloudSQLProxyMode: CloudSQLProxyMode
    var socksProxyMode: SOCKSProxyMode
    var tunnelCommandMode: TunnelCommandMode
    var safeModeLevel: SafeModeLevel
    var aiPolicy: AIConnectionPolicy?
    var aiRules: String?
    var externalAccess: ExternalAccessLevel
    var connectTimeoutSeconds: Int?
    var queryTimeoutSeconds: Int?
    var binaryInlineLimitKilobytes: Int?
    var completionIdentifierCase: SQLIdentifierCase = .default
    var commitMode: ConnectionCommitMode = .automatic
    var redisDatabase: Int?
    var startupCommands: String?
    var localOnly: Bool
    var additionalFields: [String: String]
    var ownedAdditionalFieldIDs: Set<String>
    var maskingRules: [MaskingRule] = []
    var revokedAIAlwaysAllowedTools: Set<String> = []

    static let appManagedAdditionalFieldIDs: Set<String> = [
        "preConnectScript",
        DatabaseConnection.postDisconnectScriptKey,
        DatabaseConnection.scriptTimeoutSecondsKey,
        "promptForPassword",
        DatabaseConnection.connectTimeoutSecondsKey,
        DatabaseConnection.queryTimeoutSecondsKey,
        DatabaseConnection.binaryInlineLimitKilobytesKey,
        DatabaseConnection.completionIdentifierCaseKey,
        DatabaseConnection.commitModeKey,
        DatabaseConnection.maskingRulesKey,
        DatabaseConnection.sshForwardUnixSocketPathKey,
        MySQLLocalSocket.fieldKey,
        ConnectionEnvironment.fieldKey
    ]

    func applied(to base: DatabaseConnection) -> DatabaseConnection {
        var result = base
        result.name = name
        result.host = host
        result.port = port
        result.database = database
        result.username = username
        result.type = type
        result.sshConfig = sshConfig
        result.sslConfig = sslConfig
        result.color = color
        result.iconName = iconName
        result.tagIds = tagIds
        result.groupId = groupId
        result.sshProfileId = sshProfileId
        result.sshTunnelMode = sshTunnelMode
        result.credentialMode = credentialMode
        result.cloudflareTunnelMode = cloudflareTunnelMode
        result.cloudSQLProxyMode = cloudSQLProxyMode
        result.socksProxyMode = socksProxyMode
        result.tunnelCommandMode = tunnelCommandMode
        result.preferredSafeModeLevel = safeModeLevel
        result.aiPolicy = aiPolicy
        result.aiRules = aiRules
        result.externalAccess = externalAccess
        result.redisDatabase = redisDatabase
        result.startupCommands = startupCommands
        result.localOnly = localOnly
        result.additionalFields = mergedAdditionalFields(onto: base.additionalFields)
        result.connectTimeoutSeconds = connectTimeoutSeconds
        result.queryTimeoutSeconds = queryTimeoutSeconds
        result.binaryInlineLimitKilobytes = binaryInlineLimitKilobytes
        result.completionIdentifierCase = completionIdentifierCase
        result.commitMode = commitMode
        result.maskingRules = maskingRules
        // Subtract, never assign: a grant recorded while the form was open stays.
        result.aiAlwaysAllowedTools.subtract(revokedAIAlwaysAllowedTools)
        return result
    }

    // Writes only what changed since `baseline`; typed properties sit over additionalFields keys, so both sides apply first.
    func applied(to fresh: DatabaseConnection, since baseline: ConnectionFormEdits?) -> DatabaseConnection {
        guard let baseline else { return applied(to: fresh) }
        let mine = applied(to: fresh)
        let theirs = baseline.applied(to: fresh)
        var result = fresh

        func merge<Value: Equatable>(_ keyPath: WritableKeyPath<DatabaseConnection, Value>) {
            if mine[keyPath: keyPath] != theirs[keyPath: keyPath] {
                result[keyPath: keyPath] = mine[keyPath: keyPath]
            }
        }
        merge(\.name)
        merge(\.host)
        merge(\.port)
        merge(\.database)
        merge(\.username)
        merge(\.type)
        merge(\.sslConfig)
        merge(\.color)
        merge(\.iconName)
        merge(\.tagIds)
        merge(\.groupId)
        merge(\.credentialMode)
        merge(\.preferredSafeModeLevel)
        merge(\.aiPolicy)
        merge(\.aiRules)
        merge(\.externalAccess)
        merge(\.redisDatabase)
        merge(\.startupCommands)
        merge(\.localOnly)

        // One transport at a time: a switch made here replaces the stored transports whole, and a switch another
        // writer made stays whole. Another writer's switch is read from the transport the load shows, since a record
        // an older build stored with two shows only the first.
        if mine.switchedOnTransports != theirs.switchedOnTransports {
            result.takeTransports(from: mine)
        } else if fresh.switchedOnTransports.first == theirs.switchedOnTransports.first {
            merge(\.cloudflareTunnelMode)
            merge(\.cloudSQLProxyMode)
            merge(\.socksProxyMode)
            merge(\.tunnelCommandMode)
            // One tunnel description: a half-merged trio would name a profile with another tunnel's settings.
            if mine.sshConfig != theirs.sshConfig
                || mine.sshProfileId != theirs.sshProfileId
                || mine.sshTunnelMode != theirs.sshTunnelMode {
                result.sshConfig = mine.sshConfig
                result.sshProfileId = mine.sshProfileId
                result.sshTunnelMode = mine.sshTunnelMode
            }
        }
        // So Save and Test use the transport the editor shows, never two at once, which would connect directly.
        result.keepOnlyFirstTransport()

        for key in Set(mine.additionalFields.keys).union(theirs.additionalFields.keys)
            where mine.additionalFields[key] != theirs.additionalFields[key] {
            result.additionalFields[key] = mine.additionalFields[key]
        }

        result.aiAlwaysAllowedTools.subtract(revokedAIAlwaysAllowedTools)
        return result
    }

    private func mergedAdditionalFields(onto existing: [String: String]) -> [String: String] {
        var merged = existing
        for id in ownedAdditionalFieldIDs {
            merged.removeValue(forKey: id)
        }
        for (id, value) in additionalFields {
            merged[id] = value
        }
        return merged
    }
}

extension DatabaseConnection {
    // The SSH trio counts once, whether it forwards a port or opens a remote file. In the order the editor's load picks
    // from, since an older build could store more than one.
    var switchedOnTransports: [ConnectionTunnelKind] {
        var kinds: [ConnectionTunnelKind] = []
        if sshTunnelMode != .disabled { kinds.append(.ssh) }
        if isCloudflareEnabled { kinds.append(.cloudflare) }
        if isCloudSQLProxyEnabled { kinds.append(.cloudSQLProxy) }
        if isSOCKSProxyEnabled { kinds.append(.socksProxy) }
        if isTunnelCommandEnabled { kinds.append(.tunnelCommand) }
        return kinds
    }
}

private extension DatabaseConnection {
    // SSH sorts first, so it is never one of those turned off.
    mutating func keepOnlyFirstTransport() {
        for kind in switchedOnTransports.dropFirst() {
            switch kind {
            case .cloudflare: cloudflareTunnelMode = .disabled
            case .cloudSQLProxy: cloudSQLProxyMode = .disabled
            case .socksProxy: socksProxyMode = .disabled
            case .tunnelCommand: tunnelCommandMode = .disabled
            case .ssh, .remoteFile, .remoteDatabaseSession: break
            }
        }
    }

    mutating func takeTransports(from other: DatabaseConnection) {
        sshConfig = other.sshConfig
        sshProfileId = other.sshProfileId
        sshTunnelMode = other.sshTunnelMode
        cloudflareTunnelMode = other.cloudflareTunnelMode
        cloudSQLProxyMode = other.cloudSQLProxyMode
        socksProxyMode = other.socksProxyMode
        tunnelCommandMode = other.tunnelCommandMode
        additionalFields[Self.sshForwardUnixSocketPathKey] = other.additionalFields[Self.sshForwardUnixSocketPathKey]
    }
}
