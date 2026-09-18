import Foundation
import os

/// Foreign keys for a whole browsed schema, fetched once so the data grid knows which columns
/// carry the navigation arrow before its first row is drawn.
///
/// The grid used to learn this only from the per-table metadata fetch that follows the rows, which
/// is a separate round trip on the metadata connection: the rows arrived first and the arrow
/// appeared afterwards. Reading this store during the first paint is what closes that gap.
@MainActor
final class SchemaForeignKeyStore {
    static let shared = SchemaForeignKeyStore()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "SchemaForeignKeyStore")

    private var entries: [String: [String: [ForeignKeyInfo]]] = [:]
    private var loads: [String: Task<Void, Never>] = [:]

    init() {}

    static func key(for scope: DatabaseScope) -> String {
        "\(scope.connectionId):\(scope.database):\(scope.schema ?? "")"
    }

    /// Keyed by column name, which is the shape `TableRows.columnForeignKeys` wants.
    func foreignKeysByColumn(for scope: DatabaseScope, table: String) -> [String: ForeignKeyInfo]? {
        guard let tables = entries[Self.key(for: scope)] else { return nil }
        guard let foreignKeys = tables[table] else { return [:] }
        var byColumn: [String: ForeignKeyInfo] = [:]
        for foreignKey in foreignKeys {
            byColumn[foreignKey.column] = foreignKey
        }
        return byColumn
    }

    func store(_ foreignKeys: [String: [ForeignKeyInfo]], for scope: DatabaseScope) {
        entries[Self.key(for: scope)] = foreignKeys
    }

    func invalidate(connectionId: UUID) {
        let prefix = "\(connectionId):"
        for key in entries.keys where key.hasPrefix(prefix) {
            entries.removeValue(forKey: key)
        }
        for (key, load) in loads where key.hasPrefix(prefix) {
            load.cancel()
            loads.removeValue(forKey: key)
        }
    }

    /// Runs at most one prefetch per scope, and never runs at all for a driver whose bulk fetch
    /// would degrade to one round trip per table: those answer nil, which is not cached, because
    /// "could not fetch" and "this schema has no foreign keys" must not look alike.
    ///
    /// Returns the running fetch, or nil when there is nothing to do because the scope is already
    /// fetched or already fetching.
    @discardableResult
    func prefetch(
        scope: DatabaseScope,
        using fetch: @escaping () async -> [String: [ForeignKeyInfo]]?
    ) -> Task<Void, Never>? {
        let key = Self.key(for: scope)
        guard entries[key] == nil, loads[key] == nil else { return nil }
        let load = Task { [weak self] in
            let fetched = await fetch()
            guard !Task.isCancelled else { return }
            guard let self else { return }
            loads.removeValue(forKey: key)
            guard let fetched else { return }
            entries[key] = fetched
            Self.logger.info(
                "[fk] prefetched schema foreign keys tables=\(fetched.count) scope=\(key, privacy: .public)"
            )
        }
        loads[key] = load
        return load
    }
}
