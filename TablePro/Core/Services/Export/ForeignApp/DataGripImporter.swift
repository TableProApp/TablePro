//
//  DataGripImporter.swift
//  TablePro
//

import AppKit
import Foundation
import TableProImport
import TableProPluginKit

struct DataGripImporter: ForeignAppImporter {
    let id = "datagrip"
    let displayName = "DataGrip"
    let symbolName = "cylinder.split.1x2"
    let appBundleIdentifier = "com.jetbrains.datagrip"
    let readsPasswordsFromKeychain = true

    var jetBrainsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/JetBrains")

    var savedQuerySupport: ForeignSavedQuerySupport {
        .reads(caption: String(
            localized: "Query consoles import with their data source. Consoles with a default name start unchecked."
        ))
    }

    private struct Location {
        let dataSourcesURL: URL
        let localURL: URL?
        let configDir: URL
    }

    private struct ScannedSource {
        let source: DataGripDataSource
        let configDir: URL
    }

    private struct Scan {
        var sources: [ScannedSource] = []
        var consoleSources: [DataGripConsoleReader.DataSource] = []
    }

    func isAvailable() -> Bool {
        installedAppURL() != nil || !locations().isEmpty
    }

    func inventory() -> ForeignAppInventory {
        let scan = scanDataSources(locations())
        return ForeignAppInventory(
            connections: scan.sources.count,
            savedQueries: DataGripConsoleReader.count(dataSources: scan.consoleSources, configDirs: dataGripConfigDirs())
        )
    }

    func collect(_ request: ForeignImportRequest) throws -> CollectedImport {
        let locations = locations()
        guard !locations.isEmpty else {
            throw ForeignAppImportError.fileNotFound(displayName)
        }

        let scan = scanDataSources(locations)
        var records: [ForeignConnectionRecord] = []
        var credentialsAborted = false
        var sshConfigsByDir: [URL: [String: DataGripSSHConfig]] = [:]
        var credentialStores: [URL: JetBrainsCredentialStore] = [:]

        for scanned in scan.sources {
            try Task.checkCancellation()
            let configDir = scanned.configDir
            let sshConfigs = sshConfigsByDir[configDir] ?? loadSSHConfigs(configDir: configDir)
            sshConfigsByDir[configDir] = sshConfigs

            var credentials: ExportableCredentials?
            if request.includePasswords, !credentialsAborted {
                let store = credentialStores[configDir] ?? JetBrainsCredentialStore(configDir: configDir)
                credentialStores[configDir] = store
                let collected = collectCredentials(for: scanned.source, sshConfigs: sshConfigs, store: store)
                credentials = collected.credentials
                credentialsAborted = collected.aborted
            }

            records.append(ForeignConnectionRecord(
                sourceId: scanned.source.uuid,
                settings: makeConnection(scanned.source, sshConfigs: sshConfigs),
                groupPath: scanned.source.groupName.map { [$0] } ?? [],
                credentials: credentials
            ))
        }

        let savedQueries = request.includeSavedQueries
            ? try DataGripConsoleReader.savedQueries(
                dataSources: scan.consoleSources,
                configDirs: dataGripConfigDirs(),
                limit: SavedQuerySize.maximumSyncableByteCount
            )
            : []

        return try ForeignBundleAssembly.collect(
            appName: displayName,
            connections: records,
            savedQueries: savedQueries,
            credentialsAborted: credentialsAborted
        )
    }

    // Locations run newest config dir first, so the first copy of a uuid wins. Consoles key on every uuid
    // DataGrip lists, including one TablePro cannot map to a connection.
    private func scanDataSources(_ locations: [Location]) -> Scan {
        var resolved: [String: ScannedSource] = [:]
        var fragmentsByUUID: [String: DataGripDataSourceFragment] = [:]
        var order: [String] = []
        var result = Scan()

        for location in locations {
            for fragment in fragments(at: location) {
                if fragmentsByUUID[fragment.uuid] == nil {
                    fragmentsByUUID[fragment.uuid] = fragment
                    order.append(fragment.uuid)
                }
                if resolved[fragment.uuid] == nil, let source = fragment.resolved() {
                    let scanned = ScannedSource(source: source, configDir: location.configDir)
                    resolved[fragment.uuid] = scanned
                    result.sources.append(scanned)
                }
            }
        }

        result.consoleSources = order.compactMap { uuid in
            guard let fragment = fragmentsByUUID[uuid] else { return nil }
            let source = resolved[uuid]?.source
            return DataGripConsoleReader.DataSource(
                uuid: uuid,
                isMongo: isMongo(driverRef: source?.driverRef ?? fragment.driverRef, jdbcURL: source?.jdbcURL ?? fragment.jdbcURL)
            )
        }
        return result
    }

    private func isMongo(driverRef: String?, jdbcURL: String?) -> Bool {
        let url = jdbcURL ?? ""
        if url.lowercased().hasPrefix("mongodb") { return true }
        return mapDriverRef(driverRef ?? "", subprotocol: jdbcSubprotocol(url)) == DatabaseType.mongodb.rawValue
    }

    // MARK: - Credentials

    private struct CollectedCredentials {
        var credentials: ExportableCredentials?
        var aborted: Bool
    }

    // `aborted` means the user denied Keychain access, so the caller stops prompting.
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
              let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
              let nodes = try? document.nodes(forXPath: "//entry/@key") else { return [] }

        return nodes.compactMap { node in
            node.stringValue.map { JetBrainsPathMacros.expand($0) }
        }
    }

    private func loadSSHConfigs(configDir: URL) -> [String: DataGripSSHConfig] {
        let url = configDir.appendingPathComponent("options/sshConfigs.xml")
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return DataGripDataSourceParser.parseSSHConfigs(data)
    }

    // The shared `dataSources.xml` carries the driver and JDBC URL, the machine-local
    // `dataSources.local.xml` the user name, SSH and SSL; the local file wins per field.
    private func fragments(at location: Location) -> [DataGripDataSourceFragment] {
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
        return order.compactMap { fragments[$0] }
    }

    // MARK: - Mapping

    private func makeConnection(
        _ source: DataGripDataSource,
        sshConfigs: [String: DataGripSSHConfig]
    ) -> ExportableConnection {
        let subprotocol = jdbcSubprotocol(source.jdbcURL)
        let type = mapDriverRef(source.driverRef, subprotocol: subprotocol)
        let endpoint = JDBCConnectionString.parse(url: source.jdbcURL, subprotocol: subprotocol)

        let host = endpoint?.host ?? "localhost"
        let database = endpoint?.database ?? ""
        let port = endpoint?.port ?? ForeignAppDatabaseType.defaultPort(for: type)

        return ExportableConnection(
            name: source.name,
            host: host,
            port: port,
            database: database,
            username: source.username,
            type: type,
            sshConfig: makeSSHConfig(source.ssh, sshConfigs: sshConfigs),
            sslConfig: makeSSLConfig(source.ssl)
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
        default: return ForeignAppDatabaseType.resolve(fallback)
        }
    }
}
