import Foundation
import os

/// A browsed schema's foreign keys, read when the first table load in it starts, so each table
/// paints its arrows with its first rows instead of after its own metadata round trip.
@MainActor
final class SchemaForeignKeyStore {
    static let shared = SchemaForeignKeyStore()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "SchemaForeignKeyStore")

    // By name bytes: a schema, or a database, can hold two tables or schemas whose names Swift's String equates.
    private var entries: [DatabaseScope.CatalogKey: [CatalogName: [ForeignKeyInfo]]] = [:]
    private var loads: [DatabaseScope.CatalogKey: Task<Void, Never>] = [:]

    init() {}

    /// Keyed by column name, which is the shape `TableRows.columnForeignKeys` wants.
    func foreignKeysByColumn(for scope: DatabaseScope, table: String) -> [String: ForeignKeyInfo]? {
        guard let tables = entries[scope.catalogKey] else { return nil }
        guard let foreignKeys = tables[CatalogName(table)] else { return [:] }
        var byColumn: [String: ForeignKeyInfo] = [:]
        for foreignKey in foreignKeys {
            byColumn[foreignKey.column] = foreignKey
        }
        return byColumn
    }

    // Nil until the schema's read landed, or for a session's own scope. A name the read does not list has no keys only
    // when the catalog lists it too: a name typed in SQL can differ in case from the one the read keyed.
    func listedForeignKeys(of table: String, in scope: DatabaseScope, nameIsCataloged: Bool) -> [ForeignKeyInfo]? {
        guard !scope.isSessionBound, let tables = entries[scope.catalogKey] else { return nil }
        if let foreignKeys = tables[CatalogName(table)] { return foreignKeys }
        return nameIsCataloged ? [] : nil
    }

    func store(_ foreignKeys: [CatalogName: [ForeignKeyInfo]], for scope: DatabaseScope) {
        entries[scope.catalogKey] = foreignKeys
    }

    func invalidate(connectionId: UUID) {
        for key in entries.keys where key.connectionId == connectionId {
            entries.removeValue(forKey: key)
        }
        for (key, load) in loads where key.connectionId == connectionId {
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
        using fetch: @escaping () async -> [CatalogName: [ForeignKeyInfo]]?
    ) -> Task<Void, Never>? {
        let key = scope.catalogKey
        guard entries[key] == nil, loads[key] == nil else { return nil }
        let load = Task { [weak self] in
            let fetched = await fetch()
            guard !Task.isCancelled else { return }
            guard let self else { return }
            loads.removeValue(forKey: key)
            guard let fetched else { return }
            entries[key] = fetched
            Self.logger.info(
                "[fk] prefetched schema foreign keys tables=\(fetched.count) scope=\(scope.qualifiedDescription, privacy: .private(mask: .hash))"
            )
        }
        loads[key] = load
        return load
    }
}
