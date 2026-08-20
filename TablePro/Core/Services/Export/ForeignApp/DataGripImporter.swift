//
//  DataGripImporter.swift
//  TablePro
//

import AppKit
import Foundation
import os
import TableProImport
import TableProPluginKit

struct DataGripImporter: ForeignAppImporter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DataGripImporter")

    let id = "datagrip"
    let displayName = "DataGrip"
    let symbolName = "cylinder.split.1x2"
    let appBundleIdentifier = "com.jetbrains.datagrip"
    let readsPasswordsFromKeychain = true

    /// Root holding versioned IDE config dirs (`DataGrip2024.3`, ...). Injectable for tests.
    var jetBrainsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/JetBrains")

    private struct Location {
        let dataSourcesURL: URL
        let localURL: URL?
        let configDir: URL
    }

    func isAvailable() -> Bool {
        installedAppURL() != nil || !locations().isEmpty
    }

    func connectionCount() -> Int {
        var seen = Set<String>()
        for location in locations() {
            for source in dataSources(at: location) {
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
        var sshConfigsByDir: [URL: [String: DataGripSSHConfig]] = [:]

        for location in locations {
            let sshConfigs = sshConfigsByDir[location.configDir] ?? {
                let loaded = loadSSHConfigs(configDir: location.configDir)
                sshConfigsByDir[location.configDir] = loaded
                return loaded
            }()
            let credentialStore = includePasswords ? JetBrainsCredentialStore(configDir: location.configDir) : nil

            for source in dataSources(at: location) {
                guard seenUUIDs.insert(source.uuid).inserted,
                      let connection = makeConnection(source, sshConfigs: sshConfigs) else { continue }

                let index = exportableConnections.count
                exportableConnections.append(connection)
                if let groupName = connection.groupName {
                    groupNames.insert(groupName)
                }

                if let store = credentialStore, !credentialsAborted {
                    let collected = collectCredentials(for: source, sshConfigs: sshConfigs, store: store)
                    if let resolved = collected.credentials {
                        credentials[String(index)] = resolved
                    }
                    credentialsAborted = collected.aborted
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

    // MARK: - Credentials

    private struct CollectedCredentials {
        var credentials: ExportableCredentials?
        var aborted: Bool
    }

    /// Reads the data-source password plus, when the connection tunnels over an
    /// SSH config, its saved secret: a key passphrase for key auth or a password
    /// otherwise. The SSH secret is keyed by `<host>:<port> <configId>`. `aborted`
    /// is set when the user denies Keychain access so the caller stops prompting.
    private func collectCredentials(
        for source: DataGripDataSource,
        sshConfigs: [String: DataGripSSHConfig],
        store: JetBrainsCredentialStore
    ) -> CollectedCredentials {
        var password: String?
        var sshPassword: String?
        var keyPassphrase: String?
        var aborted = false

        switch store.password(forDataSourceUUID: source.uuid) {
        case .found(let value): password = value
        case .cancelled: aborted = true
        case .notFound: break
        }

        if !aborted, let configId = source.ssh?.configId, let config = sshConfigs[configId] {
            let host = config.host
            let port = config.port ?? 22
            let usesKey = usesKeyAuthentication(authType: config.authType, keyPath: config.keyPath ?? "")
            switch usesKey
                ? store.sshKeyPassphrase(host: host, port: port, configId: configId)
                : store.sshPassword(host: host, port: port, configId: configId) {
            case .found(let value):
                if usesKey { keyPassphrase = value } else { sshPassword = value }
            case .cancelled: aborted = true
            case .notFound: break
            }
        }

        guard password != nil || sshPassword != nil || keyPassphrase != nil else {
            return CollectedCredentials(credentials: nil, aborted: aborted)
        }
        return CollectedCredentials(
            credentials: ExportableCredentials(
                password: password,
                sshPassword: sshPassword,
                keyPassphrase: keyPassphrase,
                sslClientKeyPassphrase: nil,
                totpSecret: nil,
                pluginSecureFields: nil
            ),
            aborted: aborted
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
            configDir: configDir
        ))
    }

    private func recentProjectPaths(configDir: URL) -> [String] {
        let url = configDir.appendingPathComponent("options/recentProjects.xml")
        guard let data = try? Data(contentsOf: url),
              let document = try? XMLDocument(data: data),
              let nodes = try? document.nodes(forXPath: "//entry/@key") else { return [] }

        return nodes.compactMap { node in
            node.stringValue.map { JetBrainsPathMacros.expand($0) }
        }
    }

    /// DataGrip stores SSH connection details once per IDE under
    /// `options/sshConfigs.xml`, keyed by id and referenced from each data
    /// source's `<ssh-properties><ssh-config-id>`.
    private func loadSSHConfigs(configDir: URL) -> [String: DataGripSSHConfig] {
        let url = configDir.appendingPathComponent("options/sshConfigs.xml")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return DataGripDataSourceParser.parseSSHConfigs(data)
    }

    /// Merges the shared `dataSources.xml` with the machine-local
    /// `dataSources.local.xml`. The shared file carries the driver and JDBC URL;
    /// the local file carries the user name, SSH and SSL properties. Fragments
    /// join by uuid with the local file overriding the fields it provides.
    private func dataSources(at location: Location) -> [DataGripDataSource] {
        var fragments: [String: DataGripDataSourceFragment] = [:]
        var order: [String] = []

        for url in [location.dataSourcesURL, location.localURL].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: url) else { continue }
            for fragment in DataGripDataSourceParser.parseFragments(data) {
                if fragments[fragment.uuid] == nil {
                    order.append(fragment.uuid)
                    fragments[fragment.uuid] = fragment
                } else {
                    fragments[fragment.uuid]?.merge(fragment)
                }
            }
        }
        return order.compactMap { fragments[$0]?.resolved() }
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

        let keyPath = config?.keyPath ?? ""
        let usesKey = usesKeyAuthentication(authType: config?.authType, keyPath: keyPath)

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

    /// DataGrip omits `authType` when the connection relies on the OpenSSH
    /// config, so a present key path is the reliable signal for key auth.
    private func usesKeyAuthentication(authType: String?, keyPath: String) -> Bool {
        switch (authType ?? "").uppercased() {
        case "KEY_PAIR", "PUBLIC_KEY", "OPEN_SSH":
            return true
        case "PASSWORD":
            return false
        default:
            return !keyPath.isEmpty
        }
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
