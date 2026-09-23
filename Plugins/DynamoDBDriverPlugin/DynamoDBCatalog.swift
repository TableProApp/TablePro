import Foundation

/// Where a page of a read resumes: the request of the plan, the key to start after, and for a
/// batch of GetItems, which has no key to start after, how many of its items to skip.
struct DynamoDBResumePoint: Sendable, Equatable {
    let requestIndex: Int
    let startKey: DynamoDBItem?
    let skip: Int

    static let start = DynamoDBResumePoint(requestIndex: 0, startKey: nil, skip: 0)
}

/// What the driver knows about a connection's tables, shared by every driver instance that
/// connection builds.
///
/// The app runs one connection on several driver instances: the session's, pooled ones for
/// metadata reads, and an unconnected one that only builds statements. A cache on one instance is
/// invisible to the others, so a type seen by the Structure tab never reached the save, and a
/// table changed on a pooled instance stayed stale on the session's.
final class DynamoDBCatalog: @unchecked Sendable {
    static let shared = DynamoDBCatalog()

    static let schemaLifetime: TimeInterval = 60
    static let maximumFingerprints = 64
    static let maximumResumePoints = 4_096

    struct Scope: Hashable, Sendable {
        let endpoint: String
        let region: String
        let identity: String
    }

    private struct TableKey: Hashable {
        let scope: Scope
        let table: String
    }

    private struct CachedSchema {
        let schema: DynamoDBTableSchema
        let fetchedAt: Date
    }

    private struct ResumeKey: Hashable {
        let scope: Scope
        let table: String
        let fingerprint: String
    }

    private let lock = NSLock()
    private var schemas: [TableKey: CachedSchema] = [:]
    private var columnTypes: [TableKey: [String: DynamoDBAttributeType]] = [:]
    private var resumePoints: [ResumeKey: [Int: DynamoDBResumePoint]] = [:]
    private var resumeOrder: [ResumeKey] = []

    func schema(for table: String, in scope: Scope, now: Date = Date()) -> DynamoDBTableSchema? {
        lock.withLock {
            guard let cached = schemas[TableKey(scope: scope, table: table)],
                  now.timeIntervalSince(cached.fetchedAt) < Self.schemaLifetime
            else { return nil }
            return cached.schema
        }
    }

    func cachedSchemas(in scope: Scope) -> [DynamoDBTableSchema] {
        lock.withLock {
            schemas.filter { $0.key.scope == scope }.map(\.value.schema).sorted { $0.name < $1.name }
        }
    }

    func store(_ schema: DynamoDBTableSchema, in scope: Scope, now: Date = Date()) {
        lock.withLock {
            schemas[TableKey(scope: scope, table: schema.name)] = CachedSchema(schema: schema, fetchedAt: now)
        }
    }

    /// Forgets a table after DDL: its description, the types seen in its items, and every read
    /// position of it. A table dropped and created again under the same name shares none of them.
    func invalidate(table: String, in scope: Scope) {
        lock.withLock {
            schemas[TableKey(scope: scope, table: table)] = nil
            columnTypes[TableKey(scope: scope, table: table)] = nil
        }
        forgetReadPositions { $0.scope == scope && $0.table == table }
    }

    /// Forgets where each page of a table starts, after a write. A position is the key of the item
    /// before it, so an item added or removed ahead of it moves every page after it by one.
    func forgetReadPositions(table: String, in scope: Scope) {
        forgetReadPositions { $0.scope == scope && $0.table == table }
    }

    /// Forgets every read position in a scope, for a write that names no single table.
    func forgetReadPositions(in scope: Scope) {
        forgetReadPositions { $0.scope == scope }
    }

    private func forgetReadPositions(where isStale: (ResumeKey) -> Bool) {
        lock.withLock {
            let stale = resumePoints.keys.filter(isStale)
            for key in stale {
                resumePoints[key] = nil
            }
            resumeOrder.removeAll { stale.contains($0) }
        }
    }

    func invalidateAll(in scope: Scope) {
        lock.withLock {
            schemas = schemas.filter { $0.key.scope != scope }
            columnTypes = columnTypes.filter { $0.key.scope != scope }
            resumePoints = resumePoints.filter { $0.key.scope != scope }
            resumeOrder.removeAll { $0.scope == scope }
        }
    }

    func columnTypes(for table: String, in scope: Scope) -> [String: DynamoDBAttributeType] {
        lock.withLock { columnTypes[TableKey(scope: scope, table: table)] ?? [:] }
    }

    func mergeColumnTypes(_ types: [String: DynamoDBAttributeType], for table: String, in scope: Scope) {
        guard !types.isEmpty else { return }
        lock.withLock {
            columnTypes[TableKey(scope: scope, table: table), default: [:]].merge(types) { _, new in new }
        }
    }

    // MARK: - Resume points

    func nearestResumePoint(
        table: String,
        fingerprint: String,
        atOrBefore offset: Int,
        in scope: Scope
    ) -> (offset: Int, point: DynamoDBResumePoint)? {
        lock.withLock {
            guard let points = resumePoints[ResumeKey(scope: scope, table: table, fingerprint: fingerprint)] else {
                return nil
            }
            guard let best = points.keys.filter({ $0 <= offset }).max(), let point = points[best] else { return nil }
            return (best, point)
        }
    }

    func storeResumePoint(
        _ point: DynamoDBResumePoint,
        table: String,
        fingerprint: String,
        offset: Int,
        in scope: Scope
    ) {
        let key = ResumeKey(scope: scope, table: table, fingerprint: fingerprint)
        lock.withLock {
            if resumePoints[key] == nil {
                resumeOrder.append(key)
                if resumeOrder.count > Self.maximumFingerprints {
                    let evicted = resumeOrder.removeFirst()
                    resumePoints[evicted] = nil
                }
            }
            var points = resumePoints[key] ?? [:]
            if points.count >= Self.maximumResumePoints, points[offset] == nil {
                return
            }
            points[offset] = point
            resumePoints[key] = points
        }
    }
}
