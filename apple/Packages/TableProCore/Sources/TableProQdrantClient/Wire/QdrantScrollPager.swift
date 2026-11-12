import Foundation

// The sort checks a sorted browse has already passed, so only its first page pays for them.
public final class QdrantPagingCache: @unchecked Sendable {
    private let lock = NSLock()
    private var checkedSorts: Set<String> = []

    public init() {}

    public func isSortChecked(_ key: String) -> Bool {
        lock.withLock { checkedSorts.contains(key) }
    }

    public func markSortChecked(_ key: String) {
        lock.withLock { _ = checkedSorts.insert(key) }
    }

    public func removeAll() {
        lock.withLock { checkedSorts.removeAll() }
    }
}

public extension QdrantClient {
    static let walkBatchSize = 10_000

    // A page in id order. The Query API with no query pages by id and applies the offset on the server,
    // so a page is always the rows at that offset now; a cursor cached from an earlier read would start
    // at the wrong row once another client added or removed a point before it. A node older than 1.10
    // has no Query API, so its pages walk the ids from the start.
    func pointPage(collection: String, filter: [String: Any]?, offset: Int, limit: Int) async throws -> [QdrantPoint] {
        if QdrantServerVersion.hasQueryAPI(serverVersion) {
            var body: [String: Any] = ["limit": limit, "offset": offset, "with_payload": true, "with_vector": true]
            if let filter {
                body["filter"] = filter
            }
            return try await query(collection: collection, body: body)
        }
        var position = 0
        var cursor: Any?
        while position < offset {
            try Task.checkCancellation()
            let page = try await scroll(
                collection: collection,
                body: Self.scrollBody(filter: filter, limit: min(offset - position, Self.walkBatchSize), cursor: cursor, withData: false)
            )
            guard let next = page.nextCursor else { return [] }
            position += page.points.count
            cursor = next
        }
        return try await scroll(
            collection: collection,
            body: Self.scrollBody(filter: filter, limit: limit, cursor: cursor, withData: true)
        ).points
    }

    // Without vectors this reads payloads only, which is how an export learns every key before its header. A page is
    // read only when the reader asks for the next one.
    func pointPages(
        collection: String,
        pageSize: Int,
        withVector: Bool = true
    ) -> AsyncThrowingStream<[QdrantPoint], Error> {
        let pager = QdrantPointPager(
            client: self, collection: collection, pageSize: max(pageSize, 1), withVector: withVector
        )
        return AsyncThrowingStream(unfolding: { try await pager.next() })
    }

    static func scrollBody(
        filter: [String: Any]?,
        limit: Int,
        cursor: Any?,
        withData: Bool,
        withVector: Bool? = nil
    ) -> [String: Any] {
        var body: [String: Any] = [
            "limit": limit,
            "with_payload": withData,
            "with_vector": withVector ?? withData
        ]
        if let filter {
            body["filter"] = filter
        }
        if let cursor {
            body["offset"] = cursor
        }
        return body
    }
}

// One reader pulls the pages, so one call at a time reaches the cursor.
private final class QdrantPointPager: @unchecked Sendable {
    private let client: QdrantClient
    private let collection: String
    private let pageSize: Int
    private let withVector: Bool
    private var cursor: Any?
    private var isDone = false

    init(client: QdrantClient, collection: String, pageSize: Int, withVector: Bool) {
        self.client = client
        self.collection = collection
        self.pageSize = pageSize
        self.withVector = withVector
    }

    func next() async throws -> [QdrantPoint]? {
        while !isDone {
            try Task.checkCancellation()
            let page = try await client.scroll(
                collection: collection,
                body: QdrantClient.scrollBody(
                    filter: nil, limit: pageSize, cursor: cursor, withData: true, withVector: withVector
                )
            )
            cursor = page.nextCursor
            isDone = cursor == nil
            if !page.points.isEmpty {
                return page.points
            }
        }
        return nil
    }
}
