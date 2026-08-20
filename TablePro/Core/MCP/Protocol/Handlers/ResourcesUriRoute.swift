import Foundation

public enum ResourcesUriRoute: Sendable, Equatable {
    case connections
    case connectionSchema(connectionId: UUID)
    case connectionHistory(connectionId: UUID, limit: Int, search: String?, dateFilter: String?)
    case connectionDatabases(connectionId: UUID)
    case connectionSchemas(connectionId: UUID, database: String?)
    case connectionTables(connectionId: UUID, database: String?, schema: String?, includeRowCounts: Bool)
    case tableDescription(connectionId: UUID, database: String?, schema: String?, table: String)
    case tableDefinition(connectionId: UUID, database: String?, schema: String?, table: String)
}

public extension ResourcesUriRoute {
    static let scheme = "tablepro"
    static let mimeType = "application/json"
    static let defaultHistoryLimit = 50
    static let maximumHistoryLimit = 500

    enum Template {
        public static let connections = "tablepro://connections"
        public static let schema = "tablepro://connections/{connection_id}/schema"
        public static let history = "tablepro://connections/{connection_id}/history{?limit,search,date_filter}"
        public static let databases = "tablepro://connections/{connection_id}/databases"
        public static let schemas = "tablepro://connections/{connection_id}/schemas{?database}"
        public static let tables = "tablepro://connections/{connection_id}/tables{?database,schema,row_counts}"
        public static let table = "tablepro://connections/{connection_id}/tables/{table}{?database,schema}"
        public static let tableDefinition =
            "tablepro://connections/{connection_id}/tables/{table}/ddl{?database,schema}"
    }

    var connectionId: UUID? {
        switch self {
        case .connections:
            return nil
        case .connectionSchema(let connectionId),
             .connectionDatabases(let connectionId):
            return connectionId
        case .connectionHistory(let connectionId, _, _, _):
            return connectionId
        case .connectionSchemas(let connectionId, _):
            return connectionId
        case .connectionTables(let connectionId, _, _, _):
            return connectionId
        case .tableDescription(let connectionId, _, _, _),
             .tableDefinition(let connectionId, _, _, _):
            return connectionId
        }
    }

    var cacheTtlSeconds: Int {
        switch self {
        case .connections:
            return 15
        case .connectionHistory:
            return 5
        case .tableDefinition:
            return 300
        case .connectionSchema, .connectionDatabases, .connectionSchemas, .connectionTables, .tableDescription:
            return 60
        }
    }

    static func connectionsUri() -> String {
        Template.connections
    }

    static func schemaUri(connectionId: UUID) -> String {
        connectionUri(connectionId, suffix: "schema")
    }

    static func historyUri(connectionId: UUID) -> String {
        connectionUri(connectionId, suffix: "history")
    }

    static func databasesUri(connectionId: UUID) -> String {
        connectionUri(connectionId, suffix: "databases")
    }

    static func schemasUri(connectionId: UUID) -> String {
        connectionUri(connectionId, suffix: "schemas")
    }

    static func tablesUri(connectionId: UUID) -> String {
        connectionUri(connectionId, suffix: "tables")
    }

    static func parse(uri: String) throws -> ResourcesUriRoute {
        let components = try Components(uri: uri)
        let segments = components.segments

        if segments == ["connections"] {
            return .connections
        }

        guard segments.count >= 3, segments[0] == "connections" else {
            throw unknownResource(uri)
        }
        guard let connectionId = UUID(uuidString: segments[1]) else {
            throw MCPProtocolError.invalidParams(detail: "connection id in the URI is not a UUID")
        }

        if segments.count == 3 {
            return try connectionRoute(connectionId, kind: segments[2], components: components, uri: uri)
        }
        return try tableRoute(connectionId, segments: segments, components: components, uri: uri)
    }
}

private extension ResourcesUriRoute {
    struct Components {
        let segments: [String]
        let query: [String: String]

        init(uri: String) throws {
            let prefix = "\(ResourcesUriRoute.scheme)://"
            guard uri.lowercased().hasPrefix(prefix) else {
                throw MCPProtocolError.invalidParams(detail: "URI scheme must be \(ResourcesUriRoute.scheme)")
            }
            var remainder = Substring(uri.dropFirst(prefix.count))
            if let fragment = remainder.firstIndex(of: "#") {
                remainder = remainder[..<fragment]
            }
            var rawQuery = Substring("")
            if let separator = remainder.firstIndex(of: "?") {
                rawQuery = remainder[remainder.index(after: separator)...]
                remainder = remainder[..<separator]
            }
            segments = remainder
                .split(separator: "/", omittingEmptySubsequences: true)
                .map { String($0).removingPercentEncoding ?? String($0) }
            query = Components.parseQuery(rawQuery)
        }

        func string(_ key: String) -> String? {
            guard let value = query[key], !value.isEmpty else { return nil }
            return value
        }

        func bool(_ key: String) -> Bool {
            guard let value = string(key)?.lowercased() else { return false }
            return value == "true" || value == "1" || value == "yes"
        }

        func limit(_ key: String, fallback: Int, maximum: Int) -> Int {
            guard let raw = string(key), let value = Int(raw) else { return fallback }
            return min(max(value, 1), maximum)
        }

        private static func parseQuery(_ rawQuery: Substring) -> [String: String] {
            var items: [String: String] = [:]
            for pair in rawQuery.split(separator: "&", omittingEmptySubsequences: true) {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                guard !name.isEmpty else { continue }
                let rawValue = parts.count > 1 ? String(parts[1]) : ""
                items[name] = rawValue.removingPercentEncoding ?? rawValue
            }
            return items
        }
    }

    static func connectionRoute(
        _ connectionId: UUID,
        kind: String,
        components: Components,
        uri: String
    ) throws -> ResourcesUriRoute {
        switch kind {
        case "schema":
            return .connectionSchema(connectionId: connectionId)
        case "history":
            return .connectionHistory(
                connectionId: connectionId,
                limit: components.limit("limit", fallback: defaultHistoryLimit, maximum: maximumHistoryLimit),
                search: components.string("search"),
                dateFilter: components.string("date_filter")
            )
        case "databases":
            return .connectionDatabases(connectionId: connectionId)
        case "schemas":
            return .connectionSchemas(connectionId: connectionId, database: components.string("database"))
        case "tables":
            return .connectionTables(
                connectionId: connectionId,
                database: components.string("database"),
                schema: components.string("schema"),
                includeRowCounts: components.bool("row_counts")
            )
        default:
            throw unknownResource(uri)
        }
    }

    static func tableRoute(
        _ connectionId: UUID,
        segments: [String],
        components: Components,
        uri: String
    ) throws -> ResourcesUriRoute {
        guard segments[2] == "tables" else {
            throw unknownResource(uri)
        }
        let table = segments[3]
        guard !table.isEmpty else {
            throw MCPProtocolError.invalidParams(detail: "table name in the URI is empty")
        }
        let database = components.string("database")
        let schema = components.string("schema")

        if segments.count == 4 {
            return .tableDescription(
                connectionId: connectionId,
                database: database,
                schema: schema,
                table: table
            )
        }
        guard segments.count == 5, segments[4] == "ddl" else {
            throw unknownResource(uri)
        }
        return .tableDefinition(
            connectionId: connectionId,
            database: database,
            schema: schema,
            table: table
        )
    }

    static func connectionUri(_ connectionId: UUID, suffix: String) -> String {
        "\(scheme)://connections/\(connectionId.uuidString)/\(suffix)"
    }

    static func unknownResource(_ uri: String) -> MCPProtocolError {
        MCPProtocolError.notFound(detail: "Unknown resource URI: \(uri)")
    }
}
