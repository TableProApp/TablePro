import Foundation

public struct QdrantScrollPage: @unchecked Sendable {
    public let points: [QdrantPoint]
    /// The id the next page starts from, `nil` once the collection is exhausted.
    public let nextCursor: Any?
}

public enum QdrantCursorLookup: @unchecked Sendable {
    /// Scroll from this id; `nil` is the start of the collection.
    case at(Any?)
    /// The collection ends before the requested offset.
    case pastEnd
}

public final class QdrantClient: @unchecked Sendable {
    public static let sampleSize = 100
    /// How many ids one request skips while walking to a page no cursor is held for.
    public static let skipBatchSize = 1_000

    public let settings: QdrantConnectionSettings
    private let transport: QdrantTransport
    private let timeout: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var version: String?

    public init(
        settings: QdrantConnectionSettings,
        transport: QdrantTransport,
        timeout: @escaping @Sendable () -> TimeInterval
    ) {
        self.settings = settings
        self.transport = transport
        self.timeout = timeout
    }

    public var serverVersion: String? {
        lock.withLock { version }
    }

    public func cancelAll() {
        transport.cancelAll()
    }

    public func connect(requestTimeout: @Sendable () -> TimeInterval) async throws {
        let root = try await send(method: "GET", path: "/", timeoutInterval: requestTimeout())
        try throwIfFailed(root)
        if let json = QdrantJSON.dictionary(root.json), let found = json["version"] as? String {
            lock.withLock { version = found }
        }
        try throwIfFailed(try await send(method: "GET", path: "/collections", timeoutInterval: requestTimeout()))
    }

    /// `/healthz` answers without the key, so a revoked key would leave the session looking live.
    public func ping() async throws {
        try throwIfFailed(try await send(method: "GET", path: "/collections"))
    }

    public func collectionNames() async throws -> [String] {
        let response = try await send(method: "GET", path: "/collections")
        try throwIfFailed(response)
        return QdrantSchema.collectionNames(from: response.json)
    }

    public func collection(named name: String) async throws -> QdrantCollection {
        let info = try await send(method: "GET", path: collectionPath(name))
        try throwIfFailed(info)
        let sample = try await scroll(
            collection: name,
            body: ["limit": Self.sampleSize, "with_payload": true, "with_vector": false]
        )
        return QdrantCollection.parse(name: name, info: info.json, sample: sample.points)
    }

    public func scroll(collection: String, body: [String: Any]) async throws -> QdrantScrollPage {
        let response = try await post("\(collectionPath(collection))/points/scroll", body)
        let result = (response.json as? [String: Any])?["result"] as? [String: Any]
        let points = (result?["points"] as? [Any] ?? []).compactMap(QdrantPoint.parse)
        let next = result?["next_page_offset"]
        return QdrantScrollPage(points: points, nextCursor: next is NSNull ? nil : next)
    }

    public func query(collection: String, body: [String: Any]) async throws -> [QdrantPoint] {
        let response = try await post("\(collectionPath(collection))/points/query", body)
        return QdrantPoint.list(fromResponse: response.json) ?? []
    }

    public func count(collection: String, filter: [String: Any]?) async throws -> Int {
        var body: [String: Any] = ["exact": true]
        if let filter {
            body["filter"] = filter
        }
        let response = try await post("\(collectionPath(collection))/points/count", body)
        let result = (response.json as? [String: Any])?["result"] as? [String: Any]
        guard let count = result?["count"] as? Int else {
            throw QdrantError.malformedResponse(String(localized: "Qdrant answered a count without a number."))
        }
        return count
    }

    /// Walks to the cursor of `offset` from the nearest one already known, reading ids only.
    public func cursor(
        collection: String,
        filter: [String: Any]?,
        offset: Int,
        from known: (offset: Int, cursor: Any?)
    ) async throws -> QdrantCursorLookup {
        var position = known.offset
        var cursor = known.cursor
        while position < offset {
            try Task.checkCancellation()
            let step = min(offset - position, Self.skipBatchSize)
            let page = try await scroll(
                collection: collection,
                body: QdrantBrowseQuery.scrollBody(filter: filter, limit: step, cursor: cursor, withData: false)
            )
            position += page.points.count
            guard let next = page.nextCursor else { return .pastEnd }
            cursor = next
        }
        return .at(cursor)
    }

    public func execute(_ request: QdrantConsoleRequest) async throws -> QdrantHTTPResponse {
        let response = try await send(method: request.method, path: request.path, body: request.body.map { Data($0.utf8) })
        try throwIfFailed(response)
        return response
    }

    public func send(method: String, path: String, body: Data? = nil) async throws -> QdrantHTTPResponse {
        try await send(method: method, path: path, body: body, timeoutInterval: timeout())
    }

    private func post(_ path: String, _ body: [String: Any]) async throws -> QdrantHTTPResponse {
        let response = try await send(method: "POST", path: path, body: try QdrantJSON.data(body))
        try throwIfFailed(response)
        return response
    }

    private func collectionPath(_ name: String) -> String {
        "/collections/\(QdrantPathEncoding.segment(name))"
    }

    private func send(method: String, path: String, body: Data? = nil, timeoutInterval: TimeInterval) async throws -> QdrantHTTPResponse {
        guard let url = QdrantPathEncoding.resolve(path, against: try settings.baseURL()) else {
            throw QdrantError.configuration(String(format: String(localized: "Invalid path: %@"), path))
        }
        var headers = settings.headers
        headers["Accept"] = "application/json"
        if body != nil {
            headers["Content-Type"] = "application/json"
        }
        return try await transport.send(QdrantHTTPRequest(
            method: method,
            url: url,
            headers: headers,
            body: body,
            timeoutInterval: timeoutInterval
        ))
    }

    public func throwIfFailed(_ response: QdrantHTTPResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw QdrantError.from(status: response.statusCode, body: response.body)
        }
    }
}
