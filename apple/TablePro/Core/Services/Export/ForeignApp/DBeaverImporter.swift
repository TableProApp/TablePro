//
//  DBeaverImporter.swift
//  TablePro
//

import AppKit
import CommonCrypto
import Foundation
import os
import TableProImport
import TableProPluginKit

struct DBeaverImporter: ForeignAppImporter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DBeaverImporter")

    let id = "dbeaver"
    let displayName = "DBeaver"
    let symbolName = "bird"
    let appBundleIdentifier = "org.jkiss.dbeaver.core.product"
    let readsPasswordsFromKeychain = false

    // Every edition registers its own bundle id but writes to the same `~/Library/DBeaverData/workspace*`.
    private static let knownBundleIdentifiers = [
        "org.jkiss.dbeaver.core.product",
        "org.jkiss.dbeaver.ee.core.product",
        "org.jkiss.dbeaver.ue.product",
        "org.jkiss.dbeaver.lite.product",
        "com.dbeaver.product.ultimate"
    ]

    var dbeaverDataRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DBeaverData")

    var resolveAppURL: @Sendable (_ bundleIdentifier: String) -> URL? = {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
    }

    var savedQuerySupport: ForeignSavedQuerySupport {
        .reads(caption: String(
            localized: "Scripts import with the connection they run on. Scripts with a default name start unchecked."
        ))
    }

    func installedAppURL() -> URL? {
        for bundleId in Self.knownBundleIdentifiers {
            if let url = resolveAppURL(bundleId) {
                return url
            }
        }
        return nil
    }

    func isAvailable() -> Bool {
        installedAppURL() != nil || findProject() != nil
    }

    func inventory() -> ForeignAppInventory {
        guard let project = findProject() else {
            return ForeignAppInventory(connections: 0, savedQueries: 0)
        }
        let connections = project.configs.reduce(0) { total, config in
            total + ((loadJSON(from: config.url)?["connections"] as? [String: Any])?.count ?? 0)
        }
        return ForeignAppInventory(
            connections: connections,
            savedQueries: DBeaverScriptReader.count(projectURL: project.url)
        )
    }

    func collect(_ request: ForeignImportRequest) throws -> CollectedImport {
        guard let project = findProject() else {
            throw ForeignAppImportError.fileNotFound(displayName)
        }
        let sources = try readDataSources(project)
        let folders = Self.folderDescriptions(sources)

        var records: [ForeignConnectionRecord] = []
        for source in sources {
            for (connId, connDict) in source.connections {
                try Task.checkCancellation()
                let entry = source.credentials[connId]
                var notes: [String] = []
                let settings = parseConnection(
                    connId,
                    dict: connDict,
                    credentialUsername: (entry?["#connection"] as? [String: Any])?["user"] as? String,
                    tunnelUsername: entry.flatMap { Self.tunnelField($0, "user") },
                    notes: &notes
                )
                let credentials = request.includePasswords
                    ? entry.flatMap { extractCredentials(from: $0, settings: settings) }
                    : nil
                records.append(ForeignConnectionRecord(
                    sourceId: connId,
                    settings: settings,
                    groupPath: Self.groupPath(connDict["folder"] as? String, descriptions: folders),
                    credentials: credentials,
                    notes: notes
                ))
            }
        }
        // The JSON object has no order once parsed, so sort for a stable review list.
        records.sort { ($0.settings.name, $0.sourceId ?? "") < ($1.settings.name, $1.sourceId ?? "") }

        let savedQueries = request.includeSavedQueries
            ? try DBeaverScriptReader.savedQueries(
                projectURL: project.url,
                limit: SavedQuerySize.maximumSyncableByteCount
            )
            : []

        return try ForeignBundleAssembly.collect(
            appName: displayName,
            connections: records,
            savedQueries: savedQueries,
            credentialsAborted: false
        )
    }

    // MARK: - File Discovery

    private struct Project {
        let url: URL
        let configs: [ConfigFile]
    }

    // DBeaver pairs `data-sources<sub>.json` with `credentials-config<sub>.json`.
    private struct ConfigFile {
        let name: String
        let url: URL
        let credentialsURL: URL
        let isDefault: Bool
    }

    private struct DataSources {
        let connections: [String: [String: Any]]
        let folders: [String: [String: Any]]
        let credentials: [String: [String: Any]]
    }

    private static let configPrefix = "data-sources"
    private static let credentialsPrefix = "credentials-config"
    private static let jsonExtension = ".json"

    // Sorted, so the pick never depends on the order the file system lists folders in.
    private func findProject() -> Project? {
        let fm = FileManager.default
        guard let workspaceNames = try? fm.contentsOfDirectory(atPath: dbeaverDataRoot.path) else { return nil }
        for workspaceName in workspaceNames.filter({ $0.hasPrefix("workspace") }).sorted(by: >) {
            let workspace = dbeaverDataRoot.appendingPathComponent(workspaceName, isDirectory: true)
            guard let projectNames = try? fm.contentsOfDirectory(atPath: workspace.path) else { continue }
            for projectName in projectNames.sorted() {
                let projectURL = workspace.appendingPathComponent(projectName, isDirectory: true)
                let configs = Self.configFiles(in: projectURL.appendingPathComponent(".dbeaver", isDirectory: true))
                if !configs.isEmpty {
                    return Project(url: projectURL, configs: configs)
                }
            }
        }
        return nil
    }

    private static func configFiles(in metadataFolder: URL) -> [ConfigFile] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: metadataFolder.path) else { return [] }
        let configs = names.compactMap { name -> ConfigFile? in
            guard name.hasPrefix(configPrefix), name.hasSuffix(jsonExtension),
                  name.count >= configPrefix.count + jsonExtension.count else { return nil }
            let url = metadataFolder.appendingPathComponent(name)
            let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { return nil }
            let subId = String(name.dropFirst(configPrefix.count).dropLast(jsonExtension.count))
            return ConfigFile(
                name: name,
                url: url,
                credentialsURL: metadataFolder.appendingPathComponent(credentialsPrefix + subId + jsonExtension),
                isDefault: subId.isEmpty
            )
        }
        return configs.sorted { ($0.isDefault ? 0 : 1, $0.name) < ($1.isDefault ? 0 : 1, $1.name) }
    }

    private func readDataSources(_ project: Project) throws -> [DataSources] {
        var sources: [DataSources] = []
        for config in project.configs {
            do {
                sources.append(try readConfig(config))
            } catch {
                // A broken extra file leaves the main file's connections importable.
                guard !config.isDefault else { throw error }
                Self.logger.warning("Skipped DBeaver data sources file \(config.name, privacy: .public)")
            }
        }
        return sources
    }

    private func readConfig(_ config: ConfigFile) throws -> DataSources {
        guard let json = loadJSON(from: config.url) else {
            throw ForeignAppImportError.parseError("Could not parse \(config.name)")
        }
        guard let connections = json["connections"] as? [String: [String: Any]] else {
            throw ForeignAppImportError.unsupportedFormat("Missing connections key in \(config.name)")
        }
        return DataSources(
            connections: connections,
            folders: json["folders"] as? [String: [String: Any]] ?? [:],
            credentials: loadCredentials(from: config.credentialsURL)
        )
    }

    private func loadJSON(from url: URL) -> [String: Any]? {
        guard let data = try? ForeignAppFile.read(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    // MARK: - Connection Parsing

    private func parseConnection(
        _ connId: String,
        dict: [String: Any],
        credentialUsername: String?,
        tunnelUsername: String?,
        notes: inout [String]
    ) -> ExportableConnection {
        let name = dict["name"] as? String ?? connId
        let provider = dict["provider"] as? String ?? ""
        let dbType = mapProvider(provider)

        let config = dict["configuration"] as? [String: Any] ?? [:]
        let url = (config["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // In URL mode DBeaver connects with the URL as written, and the manual fields are leftovers.
        let urlMode = config["configurationType"] as? String == "URL"
        let hostIsEmpty = (config["host"] as? String)?.isEmpty ?? true
        // Only what the URL names is kept, never the URL itself, which can hold a password.
        let endpoint = (urlMode || hostIsEmpty) ? url.flatMap(Self.endpoint) : nil
        let fromURL = urlMode && endpoint != nil
        let manual: (String) -> Any? = { fromURL ? nil : config[$0] }

        let host = (manual("host") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? endpoint?.host ?? "localhost"
        let database = manual("database") as? String ?? endpoint?.database ?? ""
        let port = Self.port(manual("port")) ?? endpoint?.port ?? ForeignAppDatabaseType.defaultPort(for: dbType)
        let username = [credentialUsername, config["user"] as? String, endpoint?.username]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? ""

        // Read whether or not the host came from the URL: a seed list and an auth database live only there.
        let additionalFields = url.map(JDBCConnectionString.urlFields) ?? [:]
        let sslConfig: ExportableSSLConfig?
        switch Self.handlerTLS(config) {
        case .on(let ssl):
            sslConfig = ssl
        case .unread(let mode):
            sslConfig = ExportableSSLConfig(mode: mode)
        case .off:
            sslConfig = url.flatMap(Self.urlSSL)
        case .absent:
            sslConfig = url.flatMap(Self.urlSSL) ?? driverDefaultSSL(dict, configuration: config, url: url, notes: &notes)
        }

        return ExportableConnection(
            name: name,
            host: host,
            port: port,
            database: database,
            username: username,
            type: dbType,
            sshConfig: parseSSHConfig(config, credentialUsername: tunnelUsername),
            sslConfig: sslConfig,
            color: parseColor(config),
            additionalFields: additionalFields.isEmpty ? nil : additionalFields
        )
    }

    private static func endpoint(_ url: String) -> JDBCConnectionString.Endpoint? {
        JDBCConnectionString.parse(url: url, subprotocol: JDBCConnectionString.subprotocol(of: url))
    }

    // A URL that sets TLS a way this cannot read keeps its own text as the mode, so the review warns.
    private static func urlSSL(_ url: String) -> ExportableSSLConfig? {
        switch JDBCConnectionString.tls(of: url) {
        case .none, .mode(.disabled):
            return nil
        case .mode(let mode):
            return ExportableSSLConfig(mode: mode.rawValue)
        case .unread(let written):
            return ExportableSSLConfig(mode: written)
        }
    }

    // The PostgreSQL drivers DBeaver ships as pgjdbc (`org.postgresql.Driver` in its plugin.xml).
    private static let pgjdbcDrivers: Set<String> = [
        "postgres-jdbc",
        "postgresql",
        "postgres-greenplum-jdbc",
        "postgres-timescale-jdbc",
        "postgres-yugabytedb-jdbc",
        "postgres-cockroach-jdbc",
        "postgres-materialize-jdbc",
        "postgres-gcloud-jdbc",
        "postgres-cratedb-jdbc",
        "postgres-risingwave-jdbc"
    ]

    // With no TLS handler DBeaver hands pgjdbc `ssl=false` and no `sslmode`, which pgjdbc reads as
    // `prefer`. Its MySQL and SQL Server connections turn TLS off outright.
    private func driverDefaultSSL(
        _ connection: [String: Any],
        configuration: [String: Any],
        url: String?,
        notes: inout [String]
    ) -> ExportableSSLConfig? {
        guard (connection["provider"] as? String)?.lowercased() == "postgresql",
              let driver = connection["driver"] as? String, Self.pgjdbcDrivers.contains(driver) else { return nil }
        if let url, JDBCConnectionString.tls(of: url) != JDBCConnectionString.TLS.none {
            return nil
        }
        // A driver property that sets TLS is not read, so its name is the mode the review flags.
        let properties = configuration["properties"] as? [String: Any] ?? [:]
        let switches = properties.keys.filter { JDBCConnectionString.isTLSParameter($0) }.sorted()
        guard switches.isEmpty else { return ExportableSSLConfig(mode: switches.joined(separator: ", ")) }
        notes.append(ForeignImportNote.tlsFromDriverDefault(.preferred, appName: displayName))
        return ExportableSSLConfig(mode: SSLMode.preferred.rawValue)
    }

    private static func port(_ value: Any?) -> Int? {
        if let number = value as? Int {
            return number
        }
        return (value as? String).flatMap { Int($0) }
    }

    // A folder defined in one file can hold connections of another, as DBeaver keeps one folder tree.
    private static func folderDescriptions(_ sources: [DataSources]) -> [String: String] {
        var descriptions: [String: String] = [:]
        for source in sources {
            for (path, folder) in source.folders where descriptions[path] == nil {
                if let description = folder["description"] as? String, !description.isEmpty {
                    descriptions[path] = description
                }
            }
        }
        return descriptions
    }

    // A folder key is its full path; a folder's description, when set, is the name DBeaver shows.
    private static func groupPath(_ folder: String?, descriptions: [String: String]) -> [String] {
        guard let folder, !folder.isEmpty else { return [] }
        let components = folder.split(separator: "/").map(String.init)
        return components.indices.map { index in
            descriptions[components[...index].joined(separator: "/")] ?? components[index]
        }
    }

    private func parseSSHConfig(_ config: [String: Any], credentialUsername: String?) -> ExportableSSHConfig? {
        guard let handlers = config["handlers"] as? [String: Any],
              let sshTunnel = handlers["ssh_tunnel"] as? [String: Any] else { return nil }

        let properties = sshTunnel["properties"] as? [String: Any] ?? [:]

        let enabled = sshTunnel["enabled"] as? Bool ?? (properties["host"] != nil)
        guard enabled else { return nil }

        let host = properties["host"] as? String ?? ""
        // DBeaver keeps the tunnel's user with its secrets, or beside its properties in an older file.
        let username = [properties["username"] as? String, sshTunnel["user"] as? String, credentialUsername]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? ""
        let authType = properties["authType"] as? String ?? "PASSWORD"
        let rawKeyPath = properties["keyPath"] as? String ?? ""
        let keyPath = ForeignAppPathHelper.resolveKeyPath(rawKeyPath)

        let authMethod: String
        switch authType {
        case "PUBLIC_KEY": authMethod = "Private Key"
        case "AGENT": authMethod = "SSH Agent"
        default: authMethod = "Password"
        }

        return ExportableSSHConfig(
            enabled: true,
            host: host,
            port: Self.port(properties["port"]),
            username: username,
            authMethod: authMethod,
            privateKeyPath: authType == "PUBLIC_KEY" ? keyPath : "",
            agentSocketPath: "",
            jumpHosts: nil,
            totpMode: nil,
            totpAlgorithm: nil,
            totpDigits: nil,
            totpPeriod: nil
        )
    }

    // MARK: - TLS

    private enum HandlerTLS {
        case absent
        case off
        case on(ExportableSSLConfig)
        case unread(String)
    }

    // DBeaver names the TLS handler per engine: `postgre_ssl`, `mysql_ssl`, `mssql_ssl`, `clickhouse-ssl`.
    private static func isTLSHandler(_ id: String) -> Bool {
        id == "ssl" || id.hasSuffix("_ssl") || id.hasSuffix("-ssl")
    }

    private static func handlerTLS(_ config: [String: Any]) -> HandlerTLS {
        let handlers = config["handlers"] as? [String: Any] ?? [:]
        var outcome = HandlerTLS.absent
        for id in handlers.keys.sorted() where isTLSHandler(id) {
            guard let handler = handlers[id] as? [String: Any], handler["enabled"] as? Bool == true else { continue }
            let properties = handler["properties"] as? [String: Any] ?? [:]
            guard let mode = tlsMode(handler: id, properties: properties) else {
                outcome = .unread(unreadMode(handler: id, properties: properties))
                continue
            }
            if mode != .disabled {
                return .on(tlsSettings(mode, properties: properties))
            }
            if case .absent = outcome {
                outcome = .off
            }
        }
        return outcome
    }

    // The mode each engine's handler hands its driver; nil when the handler keeps no mode this can read.
    private static func tlsMode(handler id: String, properties: [String: Any]) -> SSLMode? {
        func text(_ key: String) -> String? {
            (properties[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        func flag(_ key: String) -> Bool {
            properties[key] as? Bool ?? ((properties[key] as? String)?.lowercased() == "true")
        }
        switch id {
        case "postgre_ssl":
            // The PostgreSQL driver takes `ssl=true` with no mode as verify-full.
            guard let mode = text("sslMode") else { return .verifyIdentity }
            return namedMode(mode)
        case "mysql_ssl":
            // Connector/J's legacy switches: checking the certificate is verify-ca.
            if flag("ssl.verify.server") {
                return .verifyCa
            }
            return flag("ssl.require") ? .required : .preferred
        case "clickhouse-ssl":
            // The ClickHouse driver checks the server unless the mode is NONE.
            switch text("ssl.mode")?.uppercased() {
            case nil, "STRICT": return .verifyIdentity
            case "NONE": return .required
            default: return nil
            }
        default:
            return text("sslMode").flatMap(namedMode)
        }
    }

    private static func namedMode(_ mode: String) -> SSLMode? {
        switch mode.lowercased() {
        case "disable": return .disabled
        case "allow", "prefer": return .preferred
        case "require": return .required
        case "verify-ca": return .verifyCa
        case "verify-full": return .verifyIdentity
        default: return nil
        }
    }

    // The handler's own mode text, or its id when that text would read as a mode the review accepts.
    private static func unreadMode(handler id: String, properties: [String: Any]) -> String {
        let written = ["sslMode", "ssl.mode"].lazy
            .compactMap { properties[$0] as? String }
            .first { !$0.isEmpty }
        if let written, PortableSSLMode(carrying: written) == nil {
            return written
        }
        return id
    }

    // DBeaver's own keys first, then the PostgreSQL handler's older ones, then TablePro's earlier guess.
    private static func tlsSettings(_ mode: SSLMode, properties: [String: Any]) -> ExportableSSLConfig {
        func path(_ keys: String...) -> String? {
            keys.lazy.compactMap { properties[$0] as? String }.first { !$0.isEmpty }
        }
        return ExportableSSLConfig(
            mode: mode.rawValue,
            caCertificatePath: path("ssl.ca.cert", "rootCert", "caCertPath"),
            clientCertificatePath: path("ssl.client.cert", "clientCert", "clientCertPath"),
            clientKeyPath: path("ssl.client.key", "clientKey", "clientKeyPath")
        )
    }

    private func parseColor(_ config: [String: Any]) -> String? {
        guard let colorString = config["color"] as? String, !colorString.isEmpty else { return nil }
        let components = colorString.components(separatedBy: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard components.count >= 3 else { return nil }
        let (r, g, b) = (components[0], components[1], components[2])

        if r > 200 && g < 100 && b < 100 { return "Red" }
        if r > 200 && g > 100 && g < 200 && b < 100 { return "Orange" }
        if r > 200 && g > 200 && b < 100 { return "Yellow" }
        if r < 100 && g > 150 && b < 100 { return "Green" }
        if r < 100 && g < 100 && b > 200 { return "Blue" }
        if r > 100 && g < 100 && b > 150 { return "Purple" }
        return nil
    }

    // MARK: - Credentials

    private static let aesKey: [UInt8] = [
        0xBA, 0xBB, 0x4A, 0x9F, 0x77, 0x4A, 0xB8, 0x53,
        0xC9, 0x6C, 0x2D, 0x65, 0x3D, 0xFE, 0x54, 0x4A
    ]

    private func loadCredentials(from url: URL) -> [String: [String: Any]] {
        guard let data = try? ForeignAppFile.read(url),
              let decrypted = decryptCredentials(data) else { return [:] }

        guard let json = try? JSONSerialization.jsonObject(with: decrypted) as? [String: Any] else { return [:] }
        return json.compactMapValues { $0 as? [String: Any] }
    }

    private func decryptCredentials(_ data: Data) -> Data? {
        guard data.count > 16 else { return nil }

        let iv = Array(data.prefix(16))
        let ciphertext = Array(data.suffix(from: 16))

        var decryptedBytes = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var decryptedLength = 0

        let status = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES128),
            CCOptions(kCCOptionPKCS7Padding),
            Self.aesKey,
            Self.aesKey.count,
            iv,
            ciphertext,
            ciphertext.count,
            &decryptedBytes,
            decryptedBytes.count,
            &decryptedLength
        )

        guard status == kCCSuccess else {
            Self.logger.warning("DBeaver credential decryption failed with status \(status)")
            return nil
        }

        return Data(decryptedBytes.prefix(decryptedLength))
    }

    private func extractCredentials(from connCreds: [String: Any], settings: ExportableConnection) -> ExportableCredentials? {
        let connectionBlock = connCreds["#connection"] as? [String: Any] ?? [:]
        let password = connectionBlock["password"] as? String
        let tunnelSecret = Self.tunnelField(connCreds, "password")
        guard password != nil || tunnelSecret != nil else { return nil }

        // The tunnel keeps one secret: the password for password sign-in, the key's passphrase for a key.
        let keyTunnel = settings.sshConfig?.authMethod == "Private Key"
        return ExportableCredentials(
            password: password,
            sshPassword: keyTunnel ? nil : tunnelSecret,
            keyPassphrase: keyTunnel ? tunnelSecret : nil,
            sslClientKeyPassphrase: nil,
            totpSecret: nil,
            pluginSecureFields: nil
        )
    }

    // DBeaver keys a network handler's secrets `network/<handler id>`; the bare id is TablePro's earlier guess.
    private static func tunnelField(_ connCreds: [String: Any], _ field: String) -> String? {
        ["network/ssh_tunnel", "ssh_tunnel"].lazy
            .compactMap { (connCreds[$0] as? [String: Any])?[field] as? String }
            .first
    }

    // MARK: - Mapping

    private func mapProvider(_ provider: String) -> String {
        switch provider.lowercased() {
        case "mysql": return "MySQL"
        case "postgresql": return "PostgreSQL"
        case "sqlite": return "SQLite"
        case "sqlserver": return "SQL Server"
        case "oracle": return "Oracle"
        case "mongo", "mongodb": return "MongoDB"
        case "redis": return "Redis"
        case "clickhouse": return "ClickHouse"
        case "mariadb": return "MariaDB"
        case "cassandra": return "Cassandra"
        default: return ForeignAppDatabaseType.resolve(provider)
        }
    }
}
