import Foundation
import os
import TableProDatabase
import TableProModels
import TableProPluginKit
import TableProQuery
import TableProRedisCore

nonisolated final class IOSDriverFactory: DriverFactory {
    private static let logger = Logger(subsystem: "com.TablePro", category: "IOSDriverFactory")

    private let bookmarkStore: FileBookmarkStore
    private let materializer: CertificateMaterializer
    private let localFiles: LocalDatabaseFileLocator
    private let mint: IAMPasswordMint
    private let secureStore: any SecureStore
    // The session configuration of an engine reached over HTTPS, which a test points at its own URLProtocol.
    private let apiSessionConfiguration: @Sendable () -> URLSessionConfiguration

    init(
        bookmarkStore: FileBookmarkStore = FileBookmarkStore(),
        materializer: CertificateMaterializer = CertificateMaterializer(),
        localFiles: LocalDatabaseFileLocator = .live,
        mint: IAMPasswordMint = IAMPasswordMint(),
        secureStore: any SecureStore = KeychainSecureStore(),
        apiSessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .default }
    ) {
        self.bookmarkStore = bookmarkStore
        self.materializer = materializer
        self.localFiles = localFiles
        self.mint = mint
        self.secureStore = secureStore
        self.apiSessionConfiguration = apiSessionConfiguration
    }

    private func sqliteSource(for connection: DatabaseConnection) throws -> LocalDatabaseFileSource {
        try localFiles.existingSource(for: localFiles.location(forStoredPath: connection.database))
    }

    private func duckDBSource(for connection: DatabaseConnection) throws -> LocalDatabaseFileSource {
        let location = localFiles.location(forStoredPath: connection.database)
        switch location {
        case .inMemory, .appFile:
            return try localFiles.existingSource(for: location)
        case .externalFile, .notOnThisDevice:
            guard let bookmark = bookmarkStore.bookmark(for: connection.id) else {
                return try localFiles.existingSource(for: location)
            }
            return .securityScoped(try resolve(bookmark, storedPath: connection.database, for: connection.id))
        }
    }

    private func resolve(_ bookmark: Data, storedPath: String, for connectionId: UUID) throws -> URL {
        var isStale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        } catch {
            Self.logger.error("A DuckDB file bookmark no longer resolves: \(error.localizedDescription, privacy: .private)")
            throw LocalDatabaseFileError.unavailable(
                fileName: (storedPath as NSString).lastPathComponent,
                reason: .accessLost
            )
        }
        if isStale {
            refreshBookmark(of: url, for: connectionId)
        }
        return url
    }

    private func refreshBookmark(of url: URL, for connectionId: UUID) {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        do {
            bookmarkStore.save(try url.bookmarkData(), for: connectionId)
        } catch {
            Self.logger.error("Refreshing a stale DuckDB file bookmark failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func ssl(for connection: DatabaseConnection, serverName: String?) throws -> DriverSSLConfiguration {
        let declared = DriverSSLConfiguration(
            sslEnabled: connection.sslEnabled,
            configuration: connection.sslConfiguration
        )
        var resolved = declared.applying(try materializer.materialize(for: connection.id))
        try CertificatePreflight.validate(resolved)
        if connection.iamSignIn != nil, !resolved.isEnabled {
            // A token is never sent in plaintext. SSL was off, so no certificate belongs to the raised mode.
            resolved = DriverSSLConfiguration(mode: .require)
        } else if connection.iamSignIn != nil, resolved.isPreferred {
            resolved = DriverSSLConfiguration(
                mode: .require,
                caCertificatePath: resolved.caCertificatePath,
                clientCertificatePath: resolved.clientCertificatePath,
                clientKeyPath: resolved.clientKeyPath
            )
        }
        resolved.serverName = serverName
        return resolved
    }

    func resolvePassword(
        for connection: DatabaseConnection,
        stored: String?,
        secureStore: any SecureStore
    ) async throws -> String? {
        guard let method = connection.iamSignIn else { return stored }
        return try await mint.password(for: connection, method: method, secureStore: secureStore)
    }

    func createDriver(for connection: DatabaseConnection, password: String?) throws -> any DatabaseDriver {
        try createDriver(for: connection, password: password, preTunnelHost: nil)
    }

    func createDriver(
        for connection: DatabaseConnection,
        password: String?,
        preTunnelHost: String?
    ) throws -> any DatabaseDriver {
        switch connection.type {
        case .sqlite where connection.isSample:
            return SQLiteDriver(source: .file(try SampleDatabaseInstaller.live.installIfNeeded()))
        case .sqlite:
            return SQLiteDriver(source: try sqliteSource(for: connection))
        case .duckdb:
            return DuckDBDriver(source: try duckDBSource(for: connection))
        case .mysql, .mariadb, .tidb, .oceanbase:
            guard connection.macSocketPath == nil else {
                throw ConnectionError.localSocketNotSupported
            }
            return MySQLDriver(
                host: connection.host,
                port: connection.port,
                user: connection.username,
                password: password ?? "",
                database: connection.database,
                ssl: try ssl(for: connection, serverName: preTunnelHost),
                databaseType: connection.type,
                connectionEncoding: MySQLConnectionEncoding(additionalFields: connection.additionalFields),
                signsInWithToken: connection.iamSignIn != nil
            )
        case .postgresql, .redshift:
            guard connection.macSocketPath == nil else {
                throw ConnectionError.localSocketNotSupported
            }
            return PostgreSQLDriver(
                host: connection.host,
                port: connection.port,
                user: connection.username,
                password: password ?? "",
                database: connection.database,
                ssl: try ssl(for: connection, serverName: preTunnelHost),
                databaseType: connection.type
            )
        case .redis:
            let dbIndex = RedisDatabaseIndex.resolve(
                additionalFields: connection.additionalFields,
                database: connection.database
            )
            return RedisDriver(
                host: connection.host,
                port: connection.port,
                username: connection.username,
                password: password,
                database: dbIndex,
                ssl: try ssl(for: connection, serverName: preTunnelHost)
            )
        case .mssql:
            return MSSQLDriver(connection: connection, password: password)
        case .oracle:
            return OracleDriver(connection: connection, password: password, serverName: preTunnelHost)
        case .clickhouse:
            return PluginRowWritingDriver(
                plugin: ClickHousePluginDriver(config: pluginConfig(
                    for: connection,
                    password: password,
                    ssl: try ssl(for: connection, serverName: preTunnelHost),
                    preTunnelHost: preTunnelHost
                )),
                dialedHosts: [connection.host],
                queryTimeoutSeconds: connection.queryTimeoutSeconds,
                rowIdentity: .everyColumn,
                readsOnly: { !SQLWriteClassifier.isWriteQuery($0, databaseType: .clickhouse) }
            )
        case .mongodb:
            let tls = try MongoDBDialPlan.ssl(
                try ssl(for: connection, serverName: preTunnelHost),
                tunneled: preTunnelHost != nil
            )
            let config = pluginConfig(
                for: connection,
                password: password,
                ssl: tls,
                preTunnelHost: preTunnelHost,
                fields: MongoDBDialPlan.addingKeychainSecrets(
                    to: try MongoDBDialPlan.additionalFields(of: connection, preTunnelHost: preTunnelHost),
                    of: connection,
                    in: secureStore
                )
            )
            return MongoDBBackedDriver(
                mongo: MongoDBPluginDriver(config: config),
                dialedHosts: preTunnelHost == nil ? MongoDBDialPlan.seedHosts(of: connection) : [connection.host],
                queryTimeoutSeconds: connection.queryTimeoutSeconds
            )
        case .cloudflareD1:
            return CloudflareD1BackedDriver(
                d1: CloudflareD1PluginDriver(
                    config: pluginConfig(for: connection, password: password, ssl: .disabled, preTunnelHost: nil),
                    sessionConfiguration: apiSessionConfiguration()
                ),
                queryTimeoutSeconds: connection.queryTimeoutSeconds
            )
        default:
            throw ConnectionError.driverNotFound(connection.type.rawValue)
        }
    }

    static let supportedTypeList: [DatabaseType] = [
        .sqlite, .duckdb, .mysql, .mariadb, .tidb, .oceanbase, .postgresql, .redshift, .redis, .mssql, .oracle,
        .clickhouse, .mongodb, .cloudflareD1
    ]

    // A plugin reads the server behind a tunnel from its fields; one stored or imported there never stands in for it.
    func pluginConfig(
        for connection: DatabaseConnection,
        password: String?,
        ssl: DriverSSLConfiguration,
        preTunnelHost: String?,
        fields: [String: String]? = nil
    ) -> DriverConnectionConfig {
        var fields = fields ?? connection.additionalFields
        fields[DatabaseConnection.preTunnelHostKey] = preTunnelHost
        return DriverConnectionConfig(
            host: connection.host,
            port: connection.port,
            username: connection.username,
            password: password ?? "",
            database: connection.database,
            ssl: ssl.pluginConfiguration,
            additionalFields: fields
        )
    }

    // SQL Server here checks no certificate and Oracle reads no CA file, so those verify modes would skip the check.
    static func supportedSSLModes(for type: DatabaseType) -> [SSLModeChoice] {
        switch type {
        case .mssql: [.disable, .preferred, .require]
        case .oracle: [.disable, .preferred, .require, .verifyFull]
        default: [.disable, .preferred, .require, .verifyCa, .verifyFull]
        }
    }

    static func refusal(for connection: DatabaseConnection) -> ConnectionError? {
        guard supportedTypeList.contains(connection.type) else {
            return .driverNotFound(connection.type.mobileDisplayName)
        }
        guard connection.macSocketPath == nil else { return .localSocketNotSupported }
        guard !KerberosAuthFields.isSelected(in: connection.additionalFields) else { return .kerberosNotSupported }
        let sslMode = storedSSLMode(of: connection)
        // A file engine dials nothing, and an API engine always reaches its API over HTTPS: neither reads the SSL mode.
        guard !connection.type.dialsServer || supportedSSLModes(for: connection.type).contains(sslMode) else {
            return .sslModeNotSupported(mode: displayName(of: sslMode), typeName: connection.type.mobileDisplayName)
        }
        return nil
    }

    private static func storedSSLMode(of connection: DatabaseConnection) -> SSLModeChoice {
        connection.sslConfiguration.map { SSLModeChoice($0) } ?? (connection.sslEnabled ? .require : .disable)
    }

    private static func displayName(of mode: SSLModeChoice) -> String {
        switch mode {
        case .disable: String(localized: "Disabled")
        case .preferred: String(localized: "Preferred")
        case .require: String(localized: "Required")
        case .verifyCa: String(localized: "Verify CA")
        case .verifyFull: String(localized: "Verify Identity")
        }
    }

    func refusal(for connection: DatabaseConnection) -> ConnectionError? {
        Self.refusal(for: connection)
    }

    // An older form kept the tunnel of a server type switched to a file, and a D1 record can carry one from the Mac.
    func dialsSSHTunnel(for connection: DatabaseConnection) -> Bool {
        connection.sshEnabled && connection.type.dialsServer
    }

    // A second SQLite reader can make the user's COMMIT fail with SQLITE_BUSY, and DuckDB opens a file once per process.
    func opensCatalogConnections(for connection: DatabaseConnection) -> Bool {
        switch connection.type {
        case .mysql, .mariadb, .tidb, .oceanbase, .postgresql, .redshift, .mssql, .oracle:
            true
        default:
            false
        }
    }

    // MySQL: a server started with autocommit off would hold these reads in a transaction that never ends.
    // SQL Server: a catalog view read waits on the user's uncommitted DDL, so it gives up and keeps the cache.
    func prepareCatalogDriver(_ driver: any DatabaseDriver, for connection: DatabaseConnection) async throws {
        switch connection.type {
        case .mysql, .mariadb, .tidb, .oceanbase:
            _ = try await driver.execute(query: "SET autocommit = 1")
        case .mssql:
            _ = try await driver.execute(query: "SET LOCK_TIMEOUT 2000")
        default:
            break
        }
    }

    func supportedTypes() -> [DatabaseType] {
        Self.supportedTypeList
    }
}
