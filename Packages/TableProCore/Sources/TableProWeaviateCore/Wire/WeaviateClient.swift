import Foundation

public final class WeaviateClient: @unchecked Sendable {
    public let settings: WeaviateConnectionSettings
    private let transport: WeaviateTransport
    private let timeout: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var _version: String?

    public init(
        settings: WeaviateConnectionSettings,
        transport: WeaviateTransport,
        timeout: @escaping @Sendable () -> TimeInterval
    ) {
        self.settings = settings
        self.transport = transport
        self.timeout = timeout
    }

    public var serverVersion: String? {
        lock.withLock { _version }
    }

    public func cancelAll() {
        transport.cancelAll()
    }

    public func connect() async throws {
        let ready = try await send(method: "GET", path: "/v1/.well-known/ready")
        try throwIfFailed(ready)
        let meta = try await send(method: "GET", path: "/v1/meta")
        try throwIfFailed(meta)
        if let json = WeaviateJSON.dictionary(meta.json), let version = json["version"] as? String {
            lock.withLock { _version = version }
        }
    }

    /// `/v1/.well-known/ready` is the readiness probe and answers 200 with no key at all, so a
    /// revoked key would leave the health monitor reporting a session every query then fails on.
    public func ping() async throws {
        let response = try await send(method: "GET", path: "/v1/meta")
        try throwIfFailed(response)
    }

    public func schema() async throws -> [WeaviateCollection] {
        let response = try await send(method: "GET", path: "/v1/schema")
        try throwIfFailed(response)
        guard let json = response.json else {
            throw WeaviateError.malformedResponse(String(localized: "Schema response was empty."))
        }
        return WeaviateSchema.collections(from: json)
    }

    public func objects(
        collection: String,
        limit: Int,
        offset: Int,
        includeVector: Bool = true
    ) async throws -> [WeaviateObject] {
        var query = [
            "class": collection,
            "limit": String(max(limit, 0)),
            "offset": String(max(offset, 0))
        ]
        if includeVector {
            query["include"] = "vector"
        }
        let response = try await send(method: "GET", path: "/v1/objects", query: query)
        try throwIfFailed(response)
        guard let json = response.json else { return [] }
        return WeaviateObject.parseList(json)
    }

    public func graphql(_ query: String) async throws -> WeaviateHTTPResponse {
        let body = try WeaviateGraphQL.requestBody(query: query)
        let response = try await send(method: "POST", path: "/v1/graphql", body: body)
        try throwIfFailed(response)
        if let json = response.json {
            let errors = WeaviateObjectCodec.graphQLErrors(from: json)
            if !errors.isEmpty {
                throw WeaviateError.api(status: response.statusCode, message: errors.joined(separator: "\n"))
            }
        }
        return response
    }

    public func execute(write request: WeaviateWriteRequest) async throws -> WeaviateHTTPResponse {
        let body = request.body.flatMap { $0.data(using: .utf8) }
        let response = try await send(
            method: request.method,
            path: request.path,
            query: request.query,
            body: body
        )
        try throwIfFailed(response)
        return response
    }

    public func execute(console request: WeaviateConsoleRequest) async throws -> WeaviateHTTPResponse {
        let body = request.body.flatMap { $0.data(using: .utf8) }
        let response = try await send(method: request.method, path: request.path, body: body)
        try throwIfFailed(response)
        return response
    }

    public func send(
        method: String,
        path: String,
        query: [String: String] = [:],
        body: Data? = nil
    ) async throws -> WeaviateHTTPResponse {
        let base = try settings.baseURL()
        guard let url = WeaviatePathEncoding.resolve(path, query: query, against: base) else {
            throw WeaviateError.configuration(String(format: String(localized: "Invalid path: %@"), path))
        }
        var headers = [
            "Accept": "application/json"
        ]
        if body != nil {
            headers["Content-Type"] = "application/json"
        }
        if let authorization = settings.auth.authorizationHeader {
            headers["Authorization"] = authorization
        }
        let request = WeaviateHTTPRequest(
            method: method,
            url: url,
            headers: headers,
            body: body,
            timeoutInterval: timeout()
        )
        return try await transport.send(request)
    }

    public func throwIfFailed(_ response: WeaviateHTTPResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw WeaviateError.from(status: response.statusCode, body: response.body)
        }
    }
}
