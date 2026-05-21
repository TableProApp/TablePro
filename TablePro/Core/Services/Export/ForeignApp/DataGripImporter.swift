//
//  DataGripImporter.swift
//  TablePro
//

import AppKit
import Foundation
import os
import TableProPluginKit

struct DataGripImporter: ForeignAppImporter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DataGripImporter")

    let id = "datagrip"
    let displayName = "DataGrip"
    let symbolName = "cylinder.split.1x2"
    let appBundleIdentifier = "com.jetbrains.datagrip"

    /// Root holding versioned IDE config dirs (`DataGrip2024.3`, ...). Injectable for tests.
    var jetBrainsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/JetBrains")

    private struct Location {
        let dataSourcesURL: URL
        let localURL: URL?
        let sshConfigURL: URL
        let configDir: URL
    }

    func isAvailable() -> Bool {
        installedAppURL() != nil || !locations().isEmpty
    }

    func connectionCount() -> Int {
        var seen = Set<String>()
        for location in locations() {
            guard let data = try? Data(contentsOf: location.dataSourcesURL) else { continue }
            for source in DataGripDataSourceParser.parseDataSources(data) {
                seen.insert(source.uuid)
            }
        }
        return seen.count
    }

    func importConnections(includePasswords: Bool) throws -> ForeignAppImportResult {
        let locations = locations()
        guard !locations.isEmpty else {
            throw ForeignAppImportError.fileNotFound(displayName)
        }

        var seenUUIDs = Set<String>()
        var exportableConnections: [ExportableConnection] = []
        var groupNames = Set<String>()
        var credentials: [String: ExportableCredentials] = [:]
        var credentialsAborted = false

        for location in locations {
            guard let data = try? Data(contentsOf: location.dataSourcesURL) else { continue }
            var sources = DataGripDataSourceParser.parseDataSources(data)
            mergeLocalUserNames(into: &sources, localURL: location.localURL)

            let sshConfigs = loadSSHConfigs(location)
            let credentialStore = includePasswords ? JetBrainsCredentialStore(configDir: location.configDir) : nil

            for source in sources {
                guard seenUUIDs.insert(source.uuid).inserted,
                      let connection = makeConnection(source, sshConfigs: sshConfigs) else { continue }

                let index = exportableConnections.count
                exportableConnections.append(connection)
                if let groupName = connection.groupName {
                    groupNames.insert(groupName)
                }

                if let store = credentialStore, !credentialsAborted {
                    switch store.password(forDataSourceUUID: source.uuid) {
                    case .found(let password):
                        credentials[String(index)] = ExportableCredentials(
                            password: password,
                            sshPassword: nil,
                            keyPassphrase: nil,
                            totpSecret: nil,
                            pluginSecureFields: nil
                        )
                    case .cancelled:
                        credentialsAborted = true
                    case .notFound:
                        break
                    }
                }
            }
        }

        guard !exportableConnections.isEmpty else {
            throw ForeignAppImportError.noConnectionsFound
        }

        let groups: [ExportableGroup]? = groupNames.isEmpty ? nil : groupNames.map {
            ExportableGroup(name: $0, color: nil)
        }

        let envelope = ConnectionExportEnvelope(
            formatVersion: 1,
            exportedAt: Date(),
            appVersion: "DataGrip Import",
            connections: exportableConnections,
            groups: groups,
            tags: nil,
            credentials: credentials.isEmpty ? nil : credentials
        )

        return ForeignAppImportResult(
            envelope: envelope,
            sourceName: displayName,
            credentialsAborted: credentialsAborted
        )
    }

    // MARK: - Discovery

    private func locations() -> [Location] {
        var result: [Location] = []
        for configDir in dataGripConfigDirs() {
            appendLocation(directory: configDir.appendingPathComponent("options"), configDir: configDir, into: &result)

            let projectsDir = configDir.appendingPathComponent("projects")
            if let projects = try? FileManager.default.contentsOfDirectory(
                at: projectsDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for project in projects {
                    appendLocation(directory: project.appendingPathComponent(".idea"), configDir: configDir, into: &result)
                }
            }

            for projectPath in recentProjectPaths(configDir: configDir) {
                let ideaDir = URL(fileURLWithPath: projectPath).appendingPathComponent(".idea")
                appendLocation(directory: ideaDir, configDir: configDir, into: &result)
            }
        }
        return result
    }

    private func dataGripConfigDirs() -> [URL] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: jetBrainsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return dirs
            .filter { $0.lastPathComponent.hasPrefix("DataGrip") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func appendLocation(directory: URL, configDir: URL, into result: inout [Location]) {
        let dataSources = directory.appendingPathComponent("dataSources.xml")
        guard FileManager.default.fileExists(atPath: dataSources.path) else { return }

        let local = directory.appendingPathComponent("dataSources.local.xml")
        result.append(Location(
            dataSourcesURL: dataSources,
            localURL: FileManager.default.fileExists(atPath: local.path) ? local : nil,
            sshConfigURL: directory.appendingPathComponent("ssh-config.xml"),
            configDir: configDir
        ))
    }

    private func recentProjectPaths(configDir: URL) -> [String] {
        let url = configDir.appendingPathComponent("options/recentProjects.xml")
        guard let data = try? Data(contentsOf: url),
              let document = try? XMLDocument(data: data),
              let nodes = try? document.nodes(forXPath: "//entry/@key") else { return [] }

        return nodes.compactMap { node in
            node.stringValue.map { $0.replacingOccurrences(of: "$USER_HOME$", with: NSHomeDirectory()) }
        }
    }

    private func loadSSHConfigs(_ location: Location) -> [String: DataGripSSHConfig] {
        var merged: [String: DataGripSSHConfig] = [:]
        let urls = [
            location.configDir.appendingPathComponent("options/ssh-config.xml"),
            location.sshConfigURL
        ]
        for url in urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            merged.merge(DataGripDataSourceParser.parseSSHConfigs(data)) { _, new in new }
        }
        return merged
    }

    private func mergeLocalUserNames(into sources: inout [DataGripDataSource], localURL: URL?) {
        guard let localURL, let data = try? Data(contentsOf: localURL) else { return }
        let userNames = DataGripDataSourceParser.parseLocalUserNames(data)
        for index in sources.indices where sources[index].username.isEmpty {
            if let user = userNames[sources[index].uuid] {
                sources[index].username = user
            }
        }
    }

    // MARK: - Mapping

    private func makeConnection(
        _ source: DataGripDataSource,
        sshConfigs: [String: DataGripSSHConfig]
    ) -> ExportableConnection? {
        let subprotocol = jdbcSubprotocol(source.jdbcURL)
        let type = mapDriverRef(source.driverRef, subprotocol: subprotocol)
        let endpoint = JDBCConnectionString.parse(url: source.jdbcURL, subprotocol: subprotocol)

        let host = endpoint?.host ?? "localhost"
        let database = endpoint?.database ?? ""
        let port = endpoint?.port ?? defaultPort(for: type)

        return ExportableConnection(
            name: source.name,
            host: host,
            port: port,
            database: database,
            username: source.username,
            type: type,
            sshConfig: makeSSHConfig(source.ssh, sshConfigs: sshConfigs),
            sslConfig: makeSSLConfig(source.ssl),
            color: nil,
            tagName: nil,
            groupName: source.groupName,
            sshProfileId: nil,
            safeModeLevel: nil,
            aiPolicy: nil,
            additionalFields: nil,
            redisDatabase: nil,
            startupCommands: nil,
            localOnly: nil
        )
    }

    private func makeSSHConfig(
        _ reference: DataGripSSHReference?,
        sshConfigs: [String: DataGripSSHConfig]
    ) -> ExportableSSHConfig? {
        guard let reference, reference.enabled else { return nil }

        let config = reference.configId.flatMap { sshConfigs[$0] }
        let host = config?.host ?? reference.inlineHost ?? ""
        guard !host.isEmpty else { return nil }

        let authType = (config?.authType ?? "PASSWORD").uppercased()
        let usesKey = authType == "KEY_PAIR" || authType == "PUBLIC_KEY"
        let keyPath = config?.keyPath ?? ""

        return ExportableSSHConfig(
            enabled: true,
            host: host,
            port: config?.port ?? reference.inlinePort,
            username: config?.username ?? reference.inlineUser ?? "",
            authMethod: usesKey ? "Private Key" : "Password",
            privateKeyPath: usesKey ? ForeignAppPathHelper.resolveKeyPath(keyPath) : "",
            agentSocketPath: "",
            jumpHosts: nil,
            totpMode: nil,
            totpAlgorithm: nil,
            totpDigits: nil,
            totpPeriod: nil
        )
    }

    private func makeSSLConfig(_ ssl: DataGripSSLProperties?) -> ExportableSSLConfig? {
        guard let ssl else { return nil }

        let mode: String
        switch (ssl.mode ?? "").lowercased() {
        case "require", "required": mode = SSLMode.required.rawValue
        case "verify_ca", "verify-ca": mode = SSLMode.verifyCa.rawValue
        case "verify_full", "verify-full": mode = SSLMode.verifyIdentity.rawValue
        default: mode = SSLMode.preferred.rawValue
        }

        return ExportableSSLConfig(
            mode: mode,
            caCertificatePath: ssl.caCertPath,
            clientCertificatePath: ssl.clientCertPath,
            clientKeyPath: ssl.clientKeyPath
        )
    }

    private func jdbcSubprotocol(_ url: String) -> String {
        guard url.lowercased().hasPrefix("jdbc:") else { return "" }
        var subprotocol = ""
        for character in url.dropFirst("jdbc:".count) {
            if character == ":" || character == "/" { break }
            subprotocol.append(character)
        }
        return subprotocol
    }

    private func mapDriverRef(_ driverRef: String, subprotocol: String) -> String {
        let token = driverRef.lowercased().split(separator: ".").first.map(String.init) ?? driverRef.lowercased()
        switch token {
        case "mysql": return "MySQL"
        case "mariadb": return "MariaDB"
        case "postgresql", "postgres": return "PostgreSQL"
        case "sqlite": return "SQLite"
        case "sqlserver", "mssql", "jtds": return "SQL Server"
        case "oracle": return "Oracle"
        case "mongo", "mongodb": return "MongoDB"
        case "redis": return "Redis"
        case "clickhouse": return "ClickHouse"
        case "cassandra": return "Cassandra"
        case "duckdb": return "DuckDB"
        case "bigquery": return "BigQuery"
        case "cockroach", "cockroachdb": return "CockroachDB"
        case "redshift": return "Redshift"
        default: return mapSubprotocol(subprotocol, fallback: driverRef)
        }
    }

    private func mapSubprotocol(_ subprotocol: String, fallback: String) -> String {
        switch subprotocol.lowercased() {
        case "mysql": return "MySQL"
        case "mariadb": return "MariaDB"
        case "postgresql": return "PostgreSQL"
        case "sqlite": return "SQLite"
        case "sqlserver", "jtds": return "SQL Server"
        case "oracle": return "Oracle"
        case "mongodb": return "MongoDB"
        case "redis": return "Redis"
        case "clickhouse": return "ClickHouse"
        case "cassandra": return "Cassandra"
        case "duckdb": return "DuckDB"
        case "bigquery": return "BigQuery"
        default: return fallback
        }
    }

    private func defaultPort(for type: String) -> Int {
        switch type {
        case "MySQL", "MariaDB": return 3_306
        case "PostgreSQL", "CockroachDB", "Redshift": return 5_432
        case "MongoDB": return 27_017
        case "Redis": return 6_379
        case "SQL Server": return 1_433
        case "Oracle": return 1_521
        case "ClickHouse": return 8_123
        case "Cassandra": return 9_042
        default: return 0
        }
    }
}
