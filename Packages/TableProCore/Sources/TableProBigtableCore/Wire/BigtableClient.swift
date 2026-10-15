import Foundation
import TableProGoogleCloud

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
    public static let scopes = [GoogleOAuthClient.cloudPlatformScope]

    public let projectId: String
    public let appProfileId: String?
    private let requester: GoogleRESTRequester
    private let lock = NSLock()
    private var instance: String

    public init(
        projectId: String,
        instanceId: String,
        appProfileId: String? = nil,
        transport: any GoogleRESTTransport,
        credential: GoogleRESTCredential,
        timeout: @escaping @Sendable () -> TimeInterval
    ) {
        self.projectId = projectId
        self.instance = instanceId
        self.appProfileId = appProfileId
        self.requester = GoogleRESTRequester(transport: transport, credential: credential, timeout: timeout)
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
        let json = try await send("GET", Self.adminEndpoint, "projects/\(projectId)/instances", operation: String(localized: "list instances"))
        let instances = json["instances"] as? [[String: Any]] ?? []
        return instances.compactMap { Self.lastSegment($0["name"]) }.sorted()
    }

    public func listTables() async throws -> [String] {
        var names: [String] = []
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "view", value: "NAME_ONLY"), URLQueryItem(name: "pageSize", value: "1000")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let json = try await send("GET", Self.adminEndpoint, instancePath + "/tables", query: query, operation: listTablesOperation)
            names += (json["tables"] as? [[String: Any]] ?? []).compactMap { Self.lastSegment($0["name"]) }
            pageToken = (json["nextPageToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        } while pageToken != nil
        return names.sorted()
    }

    /// One page of one table name, which proves the credential, the project and the instance.
    public func ping() async throws {
        let query = [URLQueryItem(name: "view", value: "NAME_ONLY"), URLQueryItem(name: "pageSize", value: "1")]
        _ = try await send("GET", Self.adminEndpoint, instancePath + "/tables", query: query, operation: listTablesOperation)
    }

    public func columnFamilies(table: String) async throws -> [String] {
        let json = try await send(
            "GET", Self.adminEndpoint, try tablePath(table), query: [URLQueryItem(name: "view", value: "SCHEMA_VIEW")],
            operation: String(format: String(localized: "read the schema of %@"), table)
        )
        return (json["columnFamilies"] as? [String: Any] ?? [:]).keys.sorted()
    }

    // MARK: - Data

    /// A nil body is a read the filters ruled out, answered with no rows and no request.
    public func readRows(table: String, body: [String: Any]?) async throws -> [BigtableRow] {
        guard var body else { return [] }
        if let appProfileId { body["appProfileId"] = appProfileId }
        let operation = String(format: String(localized: "read %@"), table)
        let response = try await requester.send(
            method: "POST", url: try url(Self.dataEndpoint, try tablePath(table) + ":readRows"), body: try Self.encode(body)
        )
        try Self.requireSuccess(response, operation: operation)
        return try BigtableChunkAssembler.rows(fromResponse: try Self.decode(response), operation: operation)
    }

    public func mutateRow(table: String, key: Data, mutations: [BigtableMutation]) async throws {
        guard !mutations.isEmpty else { return }
        guard !key.isEmpty else {
            throw BigtableError.configuration(String(localized: "A row needs a key. Bigtable has no empty row key."))
        }
        var body: [String: Any] = ["rowKey": key.base64EncodedString(), "mutations": mutations.map(\.json)]
        if let appProfileId { body["appProfileId"] = appProfileId }
        _ = try await send("POST", Self.dataEndpoint, try tablePath(table) + ":mutateRow", body: body,
                           operation: String(format: String(localized: "write a row of %@"), table))
    }

    /// Writes a new row, refusing a key that already has one. A conditional `checkAndMutateRow`
    /// would close the gap between the check and the write, but Google refuses it under
    /// multi-cluster routing, the default app profile of a replicated instance.
    public func insertRow(table: String, key: Data, mutations: [BigtableMutation]) async throws {
        guard try await readRows(table: table, body: BigtableReadRequest.keyLookup(key)).isEmpty else {
            throw BigtableError.conflict(String(
                format: String(localized: "Row %@ already exists. Edit that row, or give the new one another key."),
                BigtableBytes.display(key)
            ))
        }
        try await mutateRow(table: table, key: key, mutations: mutations)
    }

    // MARK: - Requests

    private var listTablesOperation: String {
        String(format: String(localized: "list the tables of %@"), instanceId)
    }

    private func send(
        _ method: String,
        _ endpoint: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil,
        operation: String
    ) async throws -> [String: Any] {
        let response = try await requester.send(method: method, url: try url(endpoint, path, query: query), body: try body.map(Self.encode))
        try Self.requireSuccess(response, operation: operation)
        return try Self.decode(response) as? [String: Any] ?? [:]
    }

    private static func encode(_ body: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static func decode(_ response: GoogleRESTResponse) throws -> Any {
        guard !response.body.isEmpty else { return [String: Any]() }
        do {
            return try JSONSerialization.jsonObject(with: response.body, options: [.fragmentsAllowed])
        } catch {
            throw BigtableError.malformedResponse(String(localized: "Bigtable sent a response that is not JSON."))
        }
    }

    private static func requireSuccess(_ response: GoogleRESTResponse, operation: String) throws {
        guard !response.isSuccess else { return }
        throw BigtableError.from(status: response.statusCode, body: response.body, operation: operation)
    }

    private static func lastSegment(_ name: Any?) -> String? {
        (name as? String)?.split(separator: "/").last.map(String.init)
    }

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

public extension URLSessionGoogleRESTTransport {
    static func bigtable(resourceTimeout: TimeInterval) -> URLSessionGoogleRESTTransport {
        URLSessionGoogleRESTTransport(resourceTimeout: resourceTimeout) { BigtableError.transport($0) }
    }
}
