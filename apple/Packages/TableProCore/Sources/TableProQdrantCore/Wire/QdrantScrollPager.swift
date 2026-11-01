import Foundation

// `scroll` pages by point id, so a row offset is reached by walking ids from the nearest cursor
// already known. Every cursor a walk passes is kept, so paging on or jumping nearby costs one request.
public final class QdrantPagingCache: @unchecked Sendable {
    private static let maxQueries = 32

    private let lock = NSLock()
    private var cursors: [String: [Int: Any]] = [:]
    private var order: [String] = []
    private var checkedSorts: Set<String> = []

    public init() {}

    public func nearestCursor(at offset: Int, key: String) -> (offset: Int, cursor: Any?) {
        lock.withLock {
            guard let known = cursors[key],
                  let best = known.keys.filter({ $0 <= offset }).max()
            else { return (0, nil) }
            return (best, known[best])
        }
    }

    public func storeCursor(_ cursor: Any, at offset: Int, key: String) {
        lock.withLock {
            if cursors[key] == nil {
                order.append(key)
                if order.count > Self.maxQueries {
                    cursors[order.removeFirst()] = nil
                }
            }
            cursors[key, default: [:]][offset] = cursor
        }
    }

    public func isSortChecked(_ key: String) -> Bool {
        lock.withLock { checkedSorts.contains(key) }
    }

    public func markSortChecked(_ key: String) {
        lock.withLock { _ = checkedSorts.insert(key) }
    }

    public func removeAll() {
        lock.withLock {
            cursors.removeAll()
            order.removeAll()
            checkedSorts.removeAll()
        }
    }
}

public extension QdrantClient {
    static let walkBatchSize = 10_000

    func scrollPage(
        collection: String,
        filter: [String: Any]?,
        offset: Int,
        limit: Int,
        cache: QdrantPagingCache
    ) async throws -> [QdrantPoint] {
        let key = "\(collection)\u{0}\(filter.flatMap { try? QdrantJSON.text($0) } ?? "")"
        var (position, cursor) = cache.nearestCursor(at: offset, key: key)
        while position < offset {
            try Task.checkCancellation()
            let page = try await scroll(
                collection: collection,
                body: Self.scrollBody(filter: filter, limit: min(offset - position, Self.walkBatchSize), cursor: cursor, withData: false)
            )
            guard let next = page.nextCursor else { return [] }
            position += page.points.count
            cursor = next
            cache.storeCursor(next, at: position, key: key)
        }
        let page = try await scroll(
            collection: collection,
            body: Self.scrollBody(filter: filter, limit: limit, cursor: cursor, withData: true)
        )
        if let next = page.nextCursor {
            cache.storeCursor(next, at: offset + page.points.count, key: key)
        }
        return page.points
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
