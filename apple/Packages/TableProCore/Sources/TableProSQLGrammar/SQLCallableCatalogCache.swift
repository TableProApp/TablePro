import Foundation

// What Oracle and Dameng let a query call without parentheses, read from the session's own catalog and kept per
// connection and schema, so a query names its functions to Read-Only at the cost of one catalog read a minute.
public actor SQLCallableCatalogCache {
    public typealias Reader = @Sendable (String) async throws -> [[String?]]

    // A function or a table another session creates is seen within this long.
    private let lifetime: Duration
    // Starts timing an entry's age on the clock.
    private let stopwatch: @Sendable () -> @Sendable () -> Duration

    private struct Key: Hashable {
        let connectionId: UUID
        let schema: String?
    }

    private struct Entry<Value> {
        let value: Value
        let age: @Sendable () -> Duration
    }

    private var catalogs: [Key: Entry<SQLCallableCatalog>] = [:]
    private var columns: [Key: [SQLTableName: Entry<Set<String>>]] = [:]

    public init<C: Clock<Duration>>(lifetime: Duration = .seconds(60), clock: C = ContinuousClock()) {
        self.lifetime = lifetime
        stopwatch = {
            let start = clock.now
            return { start.duration(to: clock.now) }
        }
    }

    // Whether the query calls a function by a bare name. `read` runs one catalog query on the connection.
    public func callsFunction(
        _ reading: SQLBareNameReading,
        connectionId: UUID,
        schema: String?,
        read: Reader
    ) async throws -> Bool {
        if reading.callsOutright { return true }
        if reading.namesNothing { return false }
        let key = Key(connectionId: connectionId, schema: schema)
        let catalog = try await catalog(for: key, read: read)
        let known = try await columns(of: reading.tablesToResolve(catalog), for: key, read: read)
        return reading.callsFunction(catalog, columns: known)
    }

    private func catalog(for key: Key, read: Reader) async throws -> SQLCallableCatalog {
        if let cached = catalogs[key], cached.age() < lifetime {
            return cached.value
        }
        let age = stopwatch()
        let catalog = SQLCallableCatalog(rows: try await read(SQLCallableCatalog.query))
        catalogs[key] = Entry(value: catalog, age: age)
        return catalog
    }

    private func columns(
        of tables: Set<SQLTableName>,
        for key: Key,
        read: Reader
    ) async throws -> [SQLTableName: Set<String>] {
        guard !tables.isEmpty else { return [:] }
        var known = (columns[key] ?? [:]).filter { $0.value.age() < lifetime }
        let missing = tables.filter { known[$0] == nil }.sorted { ($0.owner ?? "", $0.name) < ($1.owner ?? "", $1.name) }
        if !missing.isEmpty, let query = SQLCallableCatalog.columnsQuery(for: missing) {
            let age = stopwatch()
            let resolved = SQLCallableCatalog.columns(fromRows: try await read(query), tables: missing)
            for table in missing {
                // A table the catalog does not resolve, or one behind a database link, is kept with no columns.
                known[table] = Entry(value: resolved[table] ?? [], age: age)
            }
        }
        columns[key] = known
        return tables.reduce(into: [:]) { result, table in
            if let entry = known[table] { result[table] = entry.value }
        }
    }
}
