//
//  ConnectionFormEdits.swift
//  TablePro
//

import Foundation

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
    var tagIds: [UUID]
    var groupId: UUID?
    var sshProfileId: UUID?
    var sshTunnelMode: SSHTunnelMode
    var cloudflareTunnelMode: CloudflareTunnelMode
    var cloudSQLProxyMode: CloudSQLProxyMode
    var socksProxyMode: SOCKSProxyMode
    var safeModeLevel: SafeModeLevel
    var aiPolicy: AIConnectionPolicy?
    var aiRules: String?
    var externalAccess: ExternalAccessLevel
    var redisDatabase: Int?
    var startupCommands: String?
    var localOnly: Bool
    var additionalFields: [String: String]
    var ownedAdditionalFieldIDs: Set<String>

    static let appManagedAdditionalFieldIDs: Set<String> = [
        "preConnectScript",
        "promptForPassword",
        DatabaseConnection.sshForwardUnixSocketPathKey
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
        result.tagIds = tagIds
        result.groupId = groupId
        result.sshProfileId = sshProfileId
        result.sshTunnelMode = sshTunnelMode
        result.cloudflareTunnelMode = cloudflareTunnelMode
        result.cloudSQLProxyMode = cloudSQLProxyMode
        result.socksProxyMode = socksProxyMode
        result.safeModeLevel = safeModeLevel
        result.aiPolicy = aiPolicy
        result.aiRules = aiRules
        result.externalAccess = externalAccess
        result.redisDatabase = redisDatabase
        result.startupCommands = startupCommands
        result.localOnly = localOnly
        result.additionalFields = mergedAdditionalFields(onto: base.additionalFields)
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
