//
//  TransientConnectionFactory.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary
import TableProPluginKit
import TableProSSHConfig

@MainActor
internal enum TransientConnectionFactory {
    internal static func build(from parsed: ParsedConnectionURL) -> DatabaseConnection {
        var sshConfig = SSHConfiguration()
        if let sshHost = parsed.sshHost {
            sshConfig.enabled = true
            sshConfig.host = sshHost
            sshConfig.port = parsed.sshPort
            sshConfig.username = parsed.sshUsername ?? ""
            if parsed.usePrivateKey == true {
                sshConfig.authMethod = .privateKey
            }
            if parsed.useSSHAgent == true {
                sshConfig.authMethod = .sshAgent
                sshConfig.agentSocketPath = parsed.agentSocket ?? ""
            }
            if parsed.sshNoAuth == true {
                sshConfig.authMethod = .none
            }
        }

        let sslConfig = SSLConfiguration(mode: parsed.sslModeResolution.mode)

        var color: ConnectionColor = .none
        if let hex = parsed.statusColor {
            color = ConnectionURLParser.connectionColor(fromHex: hex)
        }

        var tagIds: [UUID] = []
        if let envName = parsed.envTag, let resolved = ConnectionURLParser.tagId(fromEnvName: envName) {
            tagIds = [resolved]
        }

        let resolvedSafeMode = parsed.safeModeLevel.flatMap(SafeModeLevel.from(urlInteger:)) ?? .silent

        var connection = DatabaseConnection(
            name: parsed.connectionName ?? parsed.suggestedName,
            host: parsed.host,
            port: parsed.resolvedPort,
            database: parsed.database,
            username: parsed.username,
            type: parsed.type,
            sshConfig: sshConfig,
            sslConfig: sslConfig,
            color: color,
            tagIds: tagIds,
            safeModeLevel: resolvedSafeMode,
            mongoAuthSource: parsed.authSource,
            mongoUseSrv: parsed.useSrv,
            mongoAuthMechanism: parsed.mongoQueryParams["authMechanism"],
            mongoReplicaSet: parsed.mongoQueryParams["replicaSet"],
            redisDatabase: parsed.redisDatabase,
            oracleServiceName: parsed.oracleServiceName
        )

        connection.additionalFields.merge(parsed.additionalFields) { _, imported in imported }

        // The same field mapping as Import from URL, so an opened link reads legacy UUIDs the way its sender set and
        // its secrets sit where the driver and the backup tools read them. The connection is never saved.
        for (key, value) in parsed.mongoQueryParams where !value.isEmpty {
            switch key.lowercased() {
            case "authmechanism", "replicaset", "proxypassword":
                continue
            case "uuidrepresentation":
                connection.additionalFields["mongoUuidRepresentation"] = value
            case "tlscertificatekeyfile", "sslclientcertificatekeyfile":
                connection.sslConfig.clientCertificatePath = value
                connection.sslConfig.clientKeyPath = value
            case "tlscertificatekeyfilepassword", "sslclientcertificatekeypassword":
                connection.additionalFields["sslClientKeyPassphrase"] = value
            case "authmechanismproperties":
                let split = ConnectionSecretOptions.splitSessionToken(from: value)
                connection.additionalFields["mongoParam_\(key)"] = split.remaining
                connection.additionalFields[ConnectionSecretOptions.mongoSessionTokenFieldId] = split.sessionToken
            default:
                connection.additionalFields["mongoParam_\(key)"] = value
            }
        }

        return connection
    }
}
