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

    init(
        bookmarkStore: FileBookmarkStore = FileBookmarkStore(),
        materializer: CertificateMaterializer = CertificateMaterializer(),
        localFiles: LocalDatabaseFileLocator = .live,
        mint: IAMPasswordMint = IAMPasswordMint()
    ) {
        self.bookmarkStore = bookmarkStore
        self.materializer = materializer
        self.localFiles = localFiles
        self.mint = mint
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
            return OracleDriver(connection: connection, password: password)
        case .clickhouse:
            return PluginBackedDriver(
                plugin: ClickHousePluginDriver(config: pluginConfig(for: connection, password: password, ssl: try ssl(for: connection))),
                dialedHosts: [connection.host],
                queryTimeoutSeconds: connection.queryTimeoutSeconds,
                rowChangeSuffix: Self.clickHouseWaitsForMutation,
                rowIdentity: .everyColumn,
                readsOnly: { !SQLWriteClassifier.isWriteQuery($0, databaseType: .clickhouse) }
            )
        default:
            throw ConnectionError.driverNotFound(connection.type.rawValue)
        }
    }

    // A ClickHouse mutation applies in the background unless asked to wait. The row screen keeps the typed values once
    // a save returns, and a delete looks for the row right after, so both need it applied.
    static let clickHouseWaitsForMutation = " SETTINGS mutations_sync = 1"

    static let supportedTypeList: [DatabaseType] = [
        .sqlite, .duckdb, .mysql, .mariadb, .tidb, .oceanbase, .postgresql, .redshift, .redis, .mssql, .oracle,
        .clickhouse
    ]

    func pluginConfig(for connection: DatabaseConnection, password: String?, ssl: DriverSSLConfiguration) -> DriverConnectionConfig {
        DriverConnectionConfig(
            host: connection.host,
            port: connection.port,
            username: connection.username,
            password: password ?? "",
            database: connection.database,
            ssl: ssl.pluginConfiguration,
            additionalFields: connection.additionalFields
        )
    }

    static func refusal(for connection: DatabaseConnection) -> ConnectionError? {
        guard supportedTypeList.contains(connection.type) else {
            return .driverNotFound(connection.type.mobileDisplayName)
        }
        guard connection.macSocketPath == nil else { return .localSocketNotSupported }
        return nil
    }

    func refusal(for connection: DatabaseConnection) -> ConnectionError? {
        Self.refusal(for: connection)
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
