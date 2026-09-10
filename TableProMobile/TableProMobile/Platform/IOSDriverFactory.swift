import Foundation
import TableProDatabase
import TableProModels

nonisolated final class IOSDriverFactory: DriverFactory {
    private let bookmarkStore: FileBookmarkStore
    private let materializer: CertificateMaterializer

    init(
        bookmarkStore: FileBookmarkStore = FileBookmarkStore(),
        materializer: CertificateMaterializer = CertificateMaterializer()
    ) {
        self.bookmarkStore = bookmarkStore
        self.materializer = materializer
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
        case .sqlite:
            return SQLiteDriver(path: connection.database)
        case .duckdb:
            let bookmark = connection.database == DuckDBDriver.inMemoryPath
                ? nil
                : bookmarkStore.bookmark(for: connection.id)
            return DuckDBDriver(path: connection.database, bookmark: bookmark)
        case .mysql, .mariadb:
            return MySQLDriver(
                host: connection.host,
                port: connection.port,
                user: connection.username,
                password: password ?? "",
                database: connection.database,
                ssl: try ssl(for: connection)
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
        [.sqlite, .duckdb, .mysql, .mariadb, .postgresql, .redshift, .redis, .mssql, .oracle]
    }
}
