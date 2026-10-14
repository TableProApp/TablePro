import Foundation

public enum BigtableMutation: Sendable, Equatable {
    case setCell(BigtableColumn, Data)
    case deleteColumn(BigtableColumn)
    case deleteRow

    /// A timestamp of -1 asks the server to stamp the cell with its own clock, which also keeps the
    /// write valid on a table whose granularity is milliseconds.
    var json: [String: Any] {
        switch self {
        case .setCell(let column, let value):
            return ["setCell": [
                "familyName": column.family,
                "columnQualifier": column.qualifier.base64EncodedString(),
                "timestampMicros": "-1",
                "value": value.base64EncodedString()
            ]]
        case .deleteColumn(let column):
            return ["deleteFromColumn": [
                "familyName": column.family,
                "columnQualifier": column.qualifier.base64EncodedString()
            ]]
        case .deleteRow:
            return ["deleteFromRow": [String: Any]()]
        }
    }
}

/// The Bigtable data and admin REST APIs (v2) for one project and one instance at a time.
public final class BigtableClient: @unchecked Sendable {
    public static let dataEndpoint = "https://bigtable.googleapis.com/v2/"
    public static let adminEndpoint = "https://bigtableadmin.googleapis.com/v2/"

    public let projectId: String
    public let appProfileId: String?
    private let requester: BigtableRequester
    private let lock = NSLock()
    private var instance: String

    public init(
        projectId: String,
        instanceId: String,
        appProfileId: String? = nil,
        transport: any BigtableTransport,
        credential: BigtableCredential,
        timeout: @escaping @Sendable () -> TimeInterval
    ) {
        self.projectId = projectId
        self.instance = instanceId
        self.appProfileId = appProfileId
        self.requester = BigtableRequester(transport: transport, credential: credential, timeout: timeout)
    }

    public var instanceId: String {
        lock.withLock { instance }
    }

    public func switchInstance(to instanceId: String) throws {
        guard BigtableConnectionSettings.isValidResourceId(instanceId) else {
            throw BigtableError.configuration(String(format: String(localized: "\"%@\" is not a Bigtable instance ID."), instanceId))
        }
        lock.withLock { instance = instanceId }
    }

    // MARK: - Admin

    public func listInstances() async throws -> [String] {
        let response = try await requester.send(method: "GET", url: try url(Self.adminEndpoint, "projects/\(projectId)/instances"))
        try response.requireSuccess(String(localized: "list instances"))
        let instances = (try response.json() as? [String: Any])?["instances"] as? [[String: Any]] ?? []
        return instances.compactMap { ($0["name"] as? String)?.split(separator: "/").last.map(String.init) }.sorted()
    }

    public func listTables() async throws -> [String] {
        var names: [String] = []
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "view", value: "NAME_ONLY"), URLQueryItem(name: "pageSize", value: "1000")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let response = try await requester.send(method: "GET", url: try url(Self.adminEndpoint, instancePath + "/tables", query: query))
            try response.requireSuccess(String(format: String(localized: "list the tables of %@"), instanceId))
            let json = try response.json() as? [String: Any]
            let tables = json?["tables"] as? [[String: Any]] ?? []
            names += tables.compactMap { ($0["name"] as? String)?.split(separator: "/").last.map(String.init) }
            pageToken = (json?["nextPageToken"] as? String)?.nonEmpty
        } while pageToken != nil
        return names.sorted()
    }

    public func columnFamilies(table: String) async throws -> [String] {
        let response = try await requester.send(
            method: "GET",
            url: try url(Self.adminEndpoint, try tablePath(table), query: [URLQueryItem(name: "view", value: "SCHEMA_VIEW")])
        )
        try response.requireSuccess(String(format: String(localized: "read the schema of %@"), table))
        let families = (try response.json() as? [String: Any])?["columnFamilies"] as? [String: Any] ?? [:]
        return families.keys.sorted()
    }

    // MARK: - Data

    public func readRows(table: String, body: [String: Any]) async throws -> [BigtableRow] {
        if BigtableReadRequest.asksForNothing(body) { return [] }
        var request = body
        if let appProfileId { request["appProfileId"] = appProfileId }
        let response = try await requester.send(method: "POST", url: try url(Self.dataEndpoint, try tablePath(table) + ":readRows"), json: request)
        try response.requireSuccess(String(format: String(localized: "read %@"), table))
        return try BigtableChunkAssembler.rows(fromResponse: try response.json())
    }

    public func mutateRow(table: String, key: Data, mutations: [BigtableMutation]) async throws {
        guard !mutations.isEmpty else { return }
        guard !key.isEmpty else {
            throw BigtableError.configuration(String(localized: "A row needs a key. Bigtable has no empty row key."))
        }
        var body: [String: Any] = [
            "rowKey": key.base64EncodedString(),
            "mutations": mutations.map(\.json)
        ]
        if let appProfileId { body["appProfileId"] = appProfileId }
        let response = try await requester.send(method: "POST", url: try url(Self.dataEndpoint, try tablePath(table) + ":mutateRow"), json: body)
        try response.requireSuccess(String(format: String(localized: "write a row of %@"), table))
    }

    public func ping() async throws {
        _ = try await listTables()
    }

    // MARK: - Paths

    var instancePath: String {
        "projects/\(projectId)/instances/\(instanceId)"
    }

    func tablePath(_ table: String) throws -> String {
        guard BigtableConnectionSettings.isValidResourceId(table) else {
            throw BigtableError.configuration(String(format: String(localized: "\"%@\" is not a Bigtable table ID."), table))
        }
        return instancePath + "/tables/" + table
    }

    func url(_ endpoint: String, _ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(string: endpoint + path) else {
            throw BigtableError.configuration(String(format: String(localized: "\"%@\" is not a valid path."), path))
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw BigtableError.configuration(String(format: String(localized: "\"%@\" is not a valid path."), path))
        }
        return url
    }
}
