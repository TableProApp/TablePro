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

    // Without vectors this reads payloads only, which is how an export learns every key before its header.
    func pointPages(
        collection: String,
        pageSize: Int,
        withVector: Bool = true
    ) -> AsyncThrowingStream<[QdrantPoint], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var cursor: Any?
                    repeat {
                        try Task.checkCancellation()
                        let page = try await self.scroll(
                            collection: collection,
                            body: Self.scrollBody(
                                filter: nil, limit: max(pageSize, 1), cursor: cursor, withData: true, withVector: withVector
                            )
                        )
                        if !page.points.isEmpty {
                            continuation.yield(page.points)
                        }
                        cursor = page.nextCursor
                    } while cursor != nil
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
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
