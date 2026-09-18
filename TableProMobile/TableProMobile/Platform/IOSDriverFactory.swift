import Foundation
import os
import TableProDatabase
import TableProModels

nonisolated final class IOSDriverFactory: DriverFactory {
    private static let logger = Logger(subsystem: "com.TablePro", category: "IOSDriverFactory")

    private let bookmarkStore: FileBookmarkStore
    private let materializer: CertificateMaterializer
    private let localFiles: LocalDatabaseFileLocator

    init(
        bookmarkStore: FileBookmarkStore = FileBookmarkStore(),
        materializer: CertificateMaterializer = CertificateMaterializer(),
        localFiles: LocalDatabaseFileLocator = .live
    ) {
        self.bookmarkStore = bookmarkStore
        self.materializer = materializer
        self.localFiles = localFiles
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

    private func ssl(for connection: DatabaseConnection) throws -> DriverSSLConfiguration {
        let declared = DriverSSLConfiguration(
            sslEnabled: connection.sslEnabled,
            configuration: connection.sslConfiguration
        )
        let resolved = declared.applying(try materializer.materialize(for: connection.id))
        try CertificatePreflight.validate(resolved)
        return resolved
    }

    func createDriver(for connection: DatabaseConnection, password: String?) throws -> any DatabaseDriver {
        switch connection.type {
        case .sqlite where connection.isSample:
            return SQLiteDriver(source: .file(try SampleDatabaseInstaller.live.installIfNeeded()))
        case .sqlite:
            return SQLiteDriver(source: try sqliteSource(for: connection))
        case .duckdb:
            return DuckDBDriver(source: try duckDBSource(for: connection))
        case .mysql, .mariadb, .tidb, .oceanbase:
            return MySQLDriver(
                host: connection.host,
                port: connection.port,
                user: connection.username,
                password: password ?? "",
                database: connection.database,
                ssl: try ssl(for: connection),
                databaseType: connection.type,
                connectionEncoding: MySQLConnectionEncoding(additionalFields: connection.additionalFields)
            )
        case .postgresql, .redshift:
            return PostgreSQLDriver(
                host: connection.host,
                port: connection.port,
                user: connection.username,
                password: password ?? "",
                database: connection.database,
                ssl: try ssl(for: connection)
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
                ssl: try ssl(for: connection)
            )
        case .mssql:
            return MSSQLDriver(connection: connection, password: password)
        case .oracle:
            return OracleDriver(connection: connection, password: password)
        default:
            throw ConnectionError.driverNotFound(connection.type.rawValue)
        }
    }

    func supportedTypes() -> [DatabaseType] {
        [.sqlite, .duckdb, .mysql, .mariadb, .tidb, .oceanbase, .postgresql, .redshift, .redis, .mssql, .oracle]
    }
}
