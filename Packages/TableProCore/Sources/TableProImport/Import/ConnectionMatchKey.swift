import Foundation

public struct ConnectionMatchKey: Hashable, Sendable {
    // MySQLLocalSocket.fieldKey, which this package cannot import.
    private static let socketPathFieldKey = "localSocketPath"

    private let host: String
    private let port: Int
    private let database: String
    private let username: String
    // Compared exactly, since the driver passes the path to connect(2) as written.
    private let socketPath: String?

    public init(
        host: String,
        port: Int,
        database: String,
        username: String,
        redisDatabase: Int?,
        socketPath: String?
    ) {
        self.host = Self.normalized(host)
        self.port = port
        let databaseKey = Self.normalized(database)
        if databaseKey.isEmpty, let redisDatabase {
            self.database = String(redisDatabase)
        } else {
            self.database = databaseKey
        }
        self.username = Self.normalized(username)
        let socketKey = socketPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.socketPath = socketKey?.isEmpty == false ? socketKey : nil
    }

    public init(_ settings: ExportableConnection) {
        self.init(
            host: settings.host,
            port: settings.port,
            database: settings.database,
            username: settings.username,
            redisDatabase: settings.redisDatabase,
            socketPath: settings.additionalFields?[Self.socketPathFieldKey]
        )
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public enum ConnectionTypeResolver {
    public static func canonicalTypeId(_ typeId: String, registeredTypeIds: Set<String>) -> String? {
        if registeredTypeIds.contains(typeId) { return typeId }
        let folded = typeId.lowercased()
        let matches = registeredTypeIds.filter { $0.lowercased() == folded }
        guard matches.count == 1 else { return nil }
        return matches.first
    }
}
