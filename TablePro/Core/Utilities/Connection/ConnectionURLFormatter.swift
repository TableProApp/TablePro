//
//  ConnectionURLFormatter.swift
//  TablePro
//

import Foundation

struct ConnectionURLFormatter {
    static func format(_ connection: DatabaseConnection, password: String?, sshPassword: String?) -> String {
        let scheme = urlScheme(for: connection.type)

        if connection.type == .sqlite {
            return formatSQLite(connection.database)
        }

        if connection.type == .duckdb {
            return formatDuckDB(connection.database)
        }

        if connection.sshConfig.enabled {
            return formatSSH(connection, scheme: scheme, password: password)
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
        scheme: String,
        password: String?
    ) -> String {
        var result = "\(scheme)+ssh://"

        let ssh = connection.sshConfig
        if !ssh.username.isEmpty {
            result += "\(percentEncodeUserinfo(ssh.username))@"
        }
        result += ssh.host
        if ssh.port != 22 {
            result += ":\(ssh.port)"
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

        let sshPathComponent = connection.type == .oracle
            ? (connection.oracleServiceName ?? connection.database)
            : connection.database
        result += "/\(sshPathComponent)"

        let query = buildQueryString(connection)
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

        result += connection.host
        if connection.port != connection.type.defaultPort {
            result += ":\(connection.port)"
        }

        let pathComponent = connection.type == .oracle
            ? (connection.oracleServiceName ?? connection.database)
            : connection.database
        result += "/\(pathComponent)"

        let query = buildQueryString(connection)
        if !query.isEmpty {
            result += "?\(query)"
        }

        return result
    }

    private static func buildQueryString(_ connection: DatabaseConnection) -> String {
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

        if connection.sshConfig.enabled && connection.sshConfig.authMethod == .privateKey {
            params.append("usePrivateKey=true")
        }

        if connection.sshConfig.enabled && connection.sshConfig.authMethod == .sshAgent {
            params.append("useSSHAgent=true")
            if !connection.sshConfig.agentSocketPath.isEmpty {
                let encoded = connection.sshConfig.agentSocketPath
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? connection.sshConfig.agentSocketPath
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
}
