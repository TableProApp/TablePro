//
//  TransientConnectionFactory.swift
//  TablePro
//

import Foundation

@MainActor
internal enum TransientConnectionFactory {
    internal static func build(from parsed: ParsedConnectionURL) -> DatabaseConnection {
        var sshConfig = SSHConfiguration()
        if let sshHost = parsed.sshHost {
            sshConfig.enabled = true
            sshConfig.host = sshHost
            sshConfig.port = parsed.sshPort ?? 22
            sshConfig.username = parsed.sshUsername ?? ""
            if parsed.usePrivateKey == true {
                sshConfig.authMethod = .privateKey
            }
            if parsed.useSSHAgent == true {
                sshConfig.authMethod = .sshAgent
                sshConfig.agentSocketPath = parsed.agentSocket ?? ""
            }
        }

        var sslConfig = SSLConfiguration()
        if let sslMode = parsed.sslMode {
            sslConfig.mode = sslMode
        }

        var color: ConnectionColor = .none
        if let hex = parsed.statusColor {
            color = ConnectionURLParser.connectionColor(fromHex: hex)
        }

        var tagId: UUID?
        if let envName = parsed.envTag {
            tagId = ConnectionURLParser.tagId(fromEnvName: envName)
        }

        let resolvedSafeMode = parsed.safeModeLevel.flatMap(SafeModeLevel.from(urlInteger:)) ?? .silent

        var connection = DatabaseConnection(
            name: parsed.connectionName ?? parsed.suggestedName,
            host: parsed.host,
            port: parsed.port ?? parsed.type.defaultPort,
            database: parsed.database,
            username: parsed.username,
            type: parsed.type,
            sshConfig: sshConfig,
            sslConfig: sslConfig,
            color: color,
            tagId: tagId,
            safeModeLevel: resolvedSafeMode,
            mongoAuthSource: parsed.authSource,
            mongoUseSrv: parsed.useSrv,
            mongoAuthMechanism: parsed.mongoQueryParams["authMechanism"],
            mongoReplicaSet: parsed.mongoQueryParams["replicaSet"],
            redisDatabase: parsed.redisDatabase,
            oracleServiceName: parsed.oracleServiceName
        )

        for (key, value) in parsed.mongoQueryParams where !value.isEmpty {
            if key != "authMechanism" && key != "replicaSet" {
                connection.additionalFields["mongoParam_\(key)"] = value
            }
        }

        return connection
    }
}
