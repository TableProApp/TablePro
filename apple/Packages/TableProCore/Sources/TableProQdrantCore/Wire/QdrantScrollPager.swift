import Foundation

/// The grid asks for a page by row offset and `scroll` answers with the id the next page starts
/// from. This remembers that id for every page already read, so paging forward costs one request
/// and a jump costs one id-only walk from the nearest page before it.
public final class QdrantCursorCache: @unchecked Sendable {
    private static let maxQueries = 32

    private let lock = NSLock()
    private var cursors: [String: [Int: Any]] = [:]
    private var order: [String] = []

    public init() {}

    public func nearest(at offset: Int, key: String) -> (offset: Int, cursor: Any?) {
        lock.withLock {
            guard let known = cursors[key],
                  let best = known.keys.filter({ $0 <= offset }).max()
            else { return (0, nil) }
            return (best, known[best])
        }
    }

    public func store(_ cursor: Any, at offset: Int, key: String) {
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

    public func removeAll() {
        lock.withLock {
            cursors.removeAll()
            order.removeAll()
        }
    }
}

public extension QdrantClient {
    func scrollPage(
        collection: String,
        filter: [String: Any]?,
        offset: Int,
        limit: Int,
        cache: QdrantCursorCache
    ) async throws -> [QdrantPoint] {
        let filterKey = filter.flatMap { try? QdrantJSON.text($0) } ?? ""
        let key = "\(collection)\u{0}\(filterKey)"
        let start: Any?
        switch try await cursor(
            collection: collection,
            filter: filter,
            offset: offset,
            from: cache.nearest(at: offset, key: key)
        ) {
        case .pastEnd:
            return []
        case .at(let cursor):
            start = cursor
            if offset > 0, let cursor {
                cache.store(cursor, at: offset, key: key)
            }
        }
        let page = try await scroll(
            collection: collection,
            body: QdrantBrowseQuery.scrollBody(filter: filter, limit: limit, cursor: start, withData: true)
        )
        if let next = page.nextCursor {
            cache.store(next, at: offset + page.points.count, key: key)
        }
        return page.points
    }

    /// Every point of a collection a page at a time, for export. Without vectors it reads payloads only,
    /// which is how an export learns every payload key before it writes its header.
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
                            body: QdrantBrowseQuery.scrollBody(
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
}
