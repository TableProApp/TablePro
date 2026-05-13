//
//  ConnectionURLFormatter.swift
//  TablePro
//

import Foundation
import TableProPluginKit

@MainActor
struct ConnectionURLFormatter {
    static func format(
        _ connection: DatabaseConnection,
        password: String?,
        sshPassword: String?,
        sshProfile: SSHProfile? = nil
    ) -> String {
        let scheme = urlScheme(for: connection.type)

        if connection.type == .sqlite {
            return formatSQLite(connection.database)
        }

        if connection.type == .duckdb {
            return formatDuckDB(connection.database)
        }

        let ssh = connection.resolvedSSHConfig
        if ssh.enabled {
            return formatSSH(connection, sshConfig: ssh, scheme: scheme, password: password, sshPassword: sshPassword)
        }

        return formatStandard(connection, scheme: scheme, password: password)
    }

    // MARK: - Private

    private static func urlScheme(for type: DatabaseType) -> String {
        PluginMetadataRegistry.shared.snapshot(forTypeId: type.pluginTypeId)?.primaryUrlScheme
            ?? type.rawValue.lowercased()
    }

    private static func formatSQLite(_ database: String) -> String {
        if database.hasPrefix("/") {
            return "sqlite:///\(database.dropFirst())"
        }
        return "sqlite://\(database)"
    }

    private static func formatDuckDB(_ database: String) -> String {
        if database.hasPrefix("/") {
            return "duckdb:///\(database.dropFirst())"
        }
        return "duckdb://\(database)"
    }

    private static func formatSSH(
        _ connection: DatabaseConnection,
        sshConfig ssh: SSHConfiguration,
        scheme: String,
        password: String?,
        sshPassword: String?
    ) -> String {
        var result = "\(scheme)+ssh://"

        if !ssh.username.isEmpty {
            result += percentEncodeUserinfo(ssh.username)
            if let sshPassword, !sshPassword.isEmpty {
                result += ":\(percentEncodeUserinfo(sshPassword))"
            }
            result += "@"
        }
        result += ssh.host
        if let port = ssh.port, port != 22 {
            result += ":\(port)"
        }

        result += "/"

        if !connection.username.isEmpty {
            result += percentEncodeUserinfo(connection.username)
            if let password, !password.isEmpty {
                result += ":\(percentEncodeUserinfo(password))"
            }
            result += "@"
        }

        result += connection.host
        if connection.port != connection.type.defaultPort {
            result += ":\(connection.port)"
        }

        var sshPathComponent = connection.type == .oracle
            ? (connection.oracleServiceName ?? connection.database)
            : connection.database
        if connection.type == .redis, let redisDb = connection.redisDatabase, redisDb > 0 {
            sshPathComponent = String(redisDb)
        }
        result += "/\(sshPathComponent)"

        let query = buildQueryString(connection, sshConfig: ssh)
        if !query.isEmpty {
            result += "?\(query)"
        }

        return result
    }

    private static func formatStandard(
        _ connection: DatabaseConnection,
        scheme: String,
        password: String?
    ) -> String {
        var result = "\(scheme)://"

        if !connection.username.isEmpty {
            result += percentEncodeUserinfo(connection.username)
            if let password, !password.isEmpty {
                result += ":\(percentEncodeUserinfo(password))"
            }
            result += "@"
        }

        if connection.type.pluginTypeId == "MongoDB",
           let mongoHosts = connection.additionalFields["mongoHosts"], !mongoHosts.isEmpty {
            result += mongoHosts
        } else {
            result += connection.host
            if connection.port != connection.type.defaultPort {
                result += ":\(connection.port)"
            }
        }

        var pathComponent = connection.type == .oracle
            ? (connection.oracleServiceName ?? connection.database)
            : connection.database
        if connection.type == .redis, let redisDb = connection.redisDatabase, redisDb > 0 {
            pathComponent = String(redisDb)
        }
        result += "/\(pathComponent)"

        let query = buildQueryString(connection)
        if !query.isEmpty {
            result += "?\(query)"
        }

        return result
    }

    private static func buildQueryString(
        _ connection: DatabaseConnection,
        sshConfig: SSHConfiguration? = nil
    ) -> String {
        let ssh = sshConfig ?? connection.sshConfig
        var params: [String] = []

        if !connection.name.isEmpty {
            let encoded = connection.name
                .replacingOccurrences(of: " ", with: "+")
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
                .replacingOccurrences(of: "&", with: "%26")
                .replacingOccurrences(of: "=", with: "%3D")
                ?? connection.name
            params.append("name=\(encoded)")
        }

        if ssh.enabled && ssh.authMethod == .privateKey {
            params.append("usePrivateKey=true")
        }

        if ssh.enabled && ssh.authMethod == .sshAgent {
            params.append("useSSHAgent=true")
            if !ssh.agentSocketPath.isEmpty {
                let encoded = ssh.agentSocketPath
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ssh.agentSocketPath
                params.append("agentSocket=\(encoded)")
            }
        }

        if let sslParam = sslModeParam(connection.sslConfig.mode) {
            params.append("sslmode=\(sslParam)")
        }

        if let hex = colorHex(connection.color) {
            params.append("statusColor=\(hex)")
        }

        if let tagId = connection.tagId,
           let tag = TagStorage.shared.tag(for: tagId) {
            let encoded = tag.name
                .replacingOccurrences(of: " ", with: "+")
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
                .replacingOccurrences(of: "&", with: "%26")
                .replacingOccurrences(of: "=", with: "%3D")
                ?? tag.name
            params.append("env=\(encoded)")
        }

        if let authSource = connection.mongoAuthSource, !authSource.isEmpty {
            params.append("authSource=\(percentEncodeQueryValue(authSource))")
        }
        if let authMech = connection.mongoAuthMechanism, !authMech.isEmpty {
            params.append("authMechanism=\(percentEncodeQueryValue(authMech))")
        }
        if let replicaSet = connection.mongoReplicaSet, !replicaSet.isEmpty {
            params.append("replicaSet=\(percentEncodeQueryValue(replicaSet))")
        }
        if connection.mongoUseSrv {
            params.append("mongoUseSrv=true")
        }

        return params.joined(separator: "&")
    }

    private static func colorHex(_ color: ConnectionColor) -> String? {
        switch color {
        case .none: return nil
        case .red: return "FF3B30"
        case .orange: return "FF9500"
        case .yellow: return "FFCC00"
        case .green: return "34C759"
        case .blue: return "007AFF"
        case .purple: return "AF52DE"
        case .pink: return "FF2D55"
        case .gray: return "8E8E93"
        }
    }

    private static func sslModeParam(_ mode: SSLMode) -> String? {
        switch mode {
        case .disabled: return nil
        case .preferred: return "prefer"
        case .required: return "require"
        case .verifyCa: return "verify-ca"
        case .verifyIdentity: return "verify-full"
        }
    }

    private static func percentEncodeUserinfo(_ value: String) -> String {
        var allowed = CharacterSet.urlUserAllowed
        allowed.remove(charactersIn: ":@")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func percentEncodeQueryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "&", with: "%26")
            .replacingOccurrences(of: "=", with: "%3D")
            ?? value
    }
}
