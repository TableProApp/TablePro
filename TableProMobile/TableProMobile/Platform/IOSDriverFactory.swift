import Foundation
import TableProDatabase
import TableProModels

final class IOSDriverFactory: DriverFactory {
    func createDriver(for connection: DatabaseConnection, password: String?) throws -> any DatabaseDriver {
        switch connection.type {
        case .sqlite:
            return SQLiteDriver(path: connection.database)
        case .mysql, .mariadb:
            return MySQLDriver(
                host: connection.host,
                port: connection.port,
                user: connection.username,
                password: password ?? "",
                database: connection.database,
                sslEnabled: connection.sslEnabled
            )
        case .postgresql, .redshift:
            return PostgreSQLDriver(
                host: connection.host,
                port: connection.port,
                user: connection.username,
                password: password ?? "",
                database: connection.database,
                sslEnabled: connection.sslEnabled
            )
        case .redis:
            let dbIndex = Int(connection.database) ?? 0
            return RedisDriver(
                host: connection.host,
                port: connection.port,
                password: password,
                database: dbIndex,
                sslEnabled: connection.sslEnabled
            )
        default:
            throw ConnectionError.driverNotFound(connection.type.rawValue)
        }
    }

    func supportedTypes() -> [DatabaseType] {
        [.sqlite, .mysql, .mariadb, .postgresql, .redshift, .redis]
    }
}
