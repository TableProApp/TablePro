//
//  ConnectionShareLink.swift
//  TablePro
//

import Foundation
import os
import TableProImport

@MainActor
internal enum ConnectionShareLink {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionShareLink")
    private static let linkLengthWarningThreshold = 2_000

    static func deeplink(for connection: DatabaseConnection, exporter: ConnectionBundleExporter = .init()) -> String? {
        let settings = exporter.portableSettings(for: connection)

        var components = URLComponents()
        components.scheme = "tablepro"
        components.host = "import"

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "name", value: settings.name),
            URLQueryItem(name: "host", value: settings.host),
            URLQueryItem(name: "port", value: String(settings.port)),
            URLQueryItem(name: "type", value: settings.type)
        ]
        if !settings.username.isEmpty {
            queryItems.append(URLQueryItem(name: "username", value: settings.username))
        }
        if !settings.database.isEmpty {
            queryItems.append(URLQueryItem(name: "database", value: settings.database))
        }
        if let ssh = settings.sshConfig {
            queryItems.append(contentsOf: sshQueryItems(ssh))
        }
        if let ssl = settings.sslConfig {
            queryItems.append(contentsOf: sslQueryItems(ssl))
        }
        if let color = settings.color {
            queryItems.append(URLQueryItem(name: "color", value: color))
        }
        if let iconName = settings.iconName {
            queryItems.append(URLQueryItem(name: "icon", value: iconName))
        }
        for tagName in exporter.tagNames(for: connection) {
            queryItems.append(URLQueryItem(name: "tagName", value: tagName))
        }
        for groupName in exporter.groupPath(for: connection) {
            queryItems.append(URLQueryItem(name: "groupName", value: groupName))
        }
        if let safeModeLevel = settings.safeModeLevel {
            queryItems.append(URLQueryItem(name: "safeModeLevel", value: safeModeLevel))
        }
        if let aiPolicy = settings.aiPolicy {
            queryItems.append(URLQueryItem(name: "aiPolicy", value: aiPolicy))
        }
        if let connectTimeout = settings.connectTimeoutSeconds {
            queryItems.append(URLQueryItem(name: "connectTimeoutSeconds", value: String(connectTimeout)))
        }
        if let queryTimeout = settings.queryTimeoutSeconds {
            queryItems.append(URLQueryItem(name: "queryTimeoutSeconds", value: String(queryTimeout)))
        }
        if let redisDatabase = settings.redisDatabase {
            queryItems.append(URLQueryItem(name: "redisDatabase", value: String(redisDatabase)))
        }
        if let commands = settings.startupCommands, !commands.isEmpty {
            queryItems.append(URLQueryItem(name: "startupCommands", value: commands))
        }
        if settings.localOnly == true {
            queryItems.append(URLQueryItem(name: "localOnly", value: "1"))
        }
        for (key, value) in (settings.additionalFields ?? [:]).sorted(by: { $0.key < $1.key }) {
            queryItems.append(URLQueryItem(name: "af_\(key)", value: value))
        }

        components.queryItems = queryItems
        guard let link = components.url?.absoluteString, !link.isEmpty else {
            logger.warning("Could not build an import link for '\(connection.name, privacy: .private)'")
            return nil
        }
        let length = (link as NSString).length
        if length > linkLengthWarningThreshold {
            logger.warning("Import link for '\(connection.name, privacy: .private)' is \(length, privacy: .public) characters; some apps truncate links that long")
        }
        return link
    }

    static func compactJSON(for connection: DatabaseConnection, exporter: ConnectionBundleExporter = .init()) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(exporter.portableSettings(for: connection)),
              let json = String(data: data, encoding: .utf8) else {
            logger.warning("Could not encode '\(connection.name, privacy: .private)' as JSON")
            return "{}"
        }
        return json
    }

    private static func sshQueryItems(_ ssh: ExportableSSHConfig) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "ssh", value: "1"),
            URLQueryItem(name: "sshHost", value: ssh.host)
        ]
        if let port = ssh.port, port != 22 {
            items.append(URLQueryItem(name: "sshPort", value: String(port)))
        }
        if !ssh.username.isEmpty {
            items.append(URLQueryItem(name: "sshUsername", value: ssh.username))
        }
        items.append(URLQueryItem(name: "sshAuthMethod", value: ssh.authMethod))
        if !ssh.privateKeyPath.isEmpty {
            items.append(URLQueryItem(name: "sshPrivateKeyPath", value: ssh.privateKeyPath))
        }
        if !ssh.agentSocketPath.isEmpty {
            items.append(URLQueryItem(name: "sshAgentSocketPath", value: ssh.agentSocketPath))
        }
        if let jumpHosts = ssh.jumpHosts, !jumpHosts.isEmpty,
           let jumpData = try? JSONEncoder().encode(jumpHosts),
           let jumpJSON = String(data: jumpData, encoding: .utf8) {
            items.append(URLQueryItem(name: "sshJumpHosts", value: jumpJSON))
        }
        if let totpMode = ssh.totpMode {
            items.append(URLQueryItem(name: "sshTotpMode", value: totpMode))
        }
        if let totpAlgorithm = ssh.totpAlgorithm {
            items.append(URLQueryItem(name: "sshTotpAlgorithm", value: totpAlgorithm))
        }
        if let totpDigits = ssh.totpDigits {
            items.append(URLQueryItem(name: "sshTotpDigits", value: String(totpDigits)))
        }
        if let totpPeriod = ssh.totpPeriod {
            items.append(URLQueryItem(name: "sshTotpPeriod", value: String(totpPeriod)))
        }
        if let remoteFilePath = ssh.remoteFilePath, !remoteFilePath.isEmpty {
            items.append(URLQueryItem(name: "sshRemoteFilePath", value: remoteFilePath))
        }
        if let remoteFileAccess = ssh.remoteFileAccess {
            items.append(URLQueryItem(name: "sshRemoteFileAccess", value: remoteFileAccess))
        }
        return items
    }

    private static func sslQueryItems(_ ssl: ExportableSSLConfig) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "sslMode", value: ssl.mode)]
        if let path = ssl.caCertificatePath, !path.isEmpty {
            items.append(URLQueryItem(name: "sslCaCertPath", value: path))
        }
        if let path = ssl.clientCertificatePath, !path.isEmpty {
            items.append(URLQueryItem(name: "sslClientCertPath", value: path))
        }
        if let path = ssl.clientKeyPath, !path.isEmpty {
            items.append(URLQueryItem(name: "sslClientKeyPath", value: path))
        }
        return items
    }
}
