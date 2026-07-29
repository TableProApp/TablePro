import Foundation
import TableProDatabase
import TableProModels

struct IntentDatabaseSession {
    let connection: DatabaseConnection
    let session: ConnectionSession
    private let manager: ConnectionManager

    static func supportsTabularInsert(_ type: DatabaseType) -> Bool {
        switch type {
        case .mysql, .mariadb, .postgresql, .redshift, .mssql, .sqlite, .duckdb:
            return true
        default:
            return false
        }
    }

    static func open(connection: DatabaseConnection) async throws -> IntentDatabaseSession {
        guard supportsTabularInsert(connection.type) else {
            throw IntentDataError.unsupportedDatabaseType(connection.type.rawValue)
        }
        let secureStore = KeychainSecureStore()
        let sshProvider = IOSSSHProvider(secureStore: secureStore)
        let manager = ConnectionManager(
            driverFactory: IOSDriverFactory(),
            secureStore: secureStore,
            sshProvider: sshProvider
        )
        if connection.sshEnabled {
            await sshProvider.setPendingConnectionId(connection.id)
        }
        do {
            let session = try await manager.connect(connection)
            return IntentDatabaseSession(connection: connection, session: session, manager: manager)
        } catch {
            throw IntentDataError.connectionFailed(error.localizedDescription)
        }
    }

    static func with<T>(
        connectionId: UUID,
        _ body: (IntentDatabaseSession) async throws -> T
    ) async throws -> T {
        guard let connection = IntentConnectionLoader.connection(id: connectionId) else {
            throw IntentDataError.connectionNotFound
        }
        return try await with(connection: connection, body)
    }

    static func with<T>(
        connection: DatabaseConnection,
        _ body: (IntentDatabaseSession) async throws -> T
    ) async throws -> T {
        let session = try await open(connection: connection)
        do {
            let result = try await body(session)
            await session.close()
            return result
        } catch {
            await session.close()
            throw error
        }
    }

    func close() async {
        await manager.disconnect(connection.id)
    }

    func namespaces() async throws -> [DatabaseEntity] {
        let driver = session.driver
        if driver.supportsSchemas {
            return try await driver.fetchSchemas().map { DatabaseEntity(id: $0, name: $0, kind: .schema) }
        }
        return try await driver.fetchDatabases().map { DatabaseEntity(id: $0, name: $0, kind: .database) }
    }

    func tables(namespace: String?) async throws -> [TableEntity] {
        let schema = try await resolveSchema(namespace: namespace)
        return try await session.driver.fetchTables(schema: schema).map { TableEntity(id: $0.name, name: $0.name) }
    }

    func insertRows(namespace: String?, table: String, rows: [PayloadRow]) async throws -> Int {
        let schema = try await resolveSchema(namespace: namespace)
        return try await RowInserter.insert(
            driver: session.driver,
            table: table,
            type: connection.type,
            schema: schema,
            rows: rows
        )
    }

    private func resolveSchema(namespace: String?) async throws -> String? {
        let driver = session.driver
        guard let namespace, !namespace.isEmpty else {
            return driver.supportsSchemas ? driver.currentSchema : nil
        }
        if driver.supportsSchemas {
            return namespace
        }
        try await driver.switchDatabase(to: namespace)
        return nil
    }
}
