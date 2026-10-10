import Foundation

public struct ConnectionMatchKey: Hashable, Sendable {
    private let host: String
    private let port: Int
    private let database: String
    private let username: String

    public init(host: String, port: Int, database: String, username: String, redisDatabase: Int?) {
        self.host = Self.normalized(host)
        self.port = port
        let databaseKey = Self.normalized(database)
        if databaseKey.isEmpty, let redisDatabase {
            self.database = String(redisDatabase)
        } else {
            self.database = databaseKey
        }
        self.username = Self.normalized(username)
    }

    public init(_ settings: ExportableConnection) {
        self.init(
            host: settings.host,
            port: settings.port,
            database: settings.database,
            username: settings.username,
            redisDatabase: settings.redisDatabase
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
