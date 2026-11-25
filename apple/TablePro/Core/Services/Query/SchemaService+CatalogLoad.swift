//
//  SchemaService+CatalogLoad.swift
//  TablePro
//
//  How one load reads a catalog: on one driver the caller holds, or on a lease per read.
//

import Foundation
import os
import TableProPluginKit

extension SchemaService {
    // One lease per read, so a column read asked for meanwhile goes before the next kind instead of after
    // the whole catalog, and a session lent to one read is never held across the catalog. The tables lease
    // opens before any state moves: a refused lease leaves it untouched.
    func load(
        connectionId: UUID,
        connection: DatabaseConnection,
        scope: DatabaseScope,
        leasingFrom provider: any ScopedMetadataProviding,
        afterTables: (@MainActor () async -> Void)? = nil
    ) async throws {
        // A catalog already loaded still hands its tables over: completion may have dropped its copy.
        guard needsLoad(connectionId, scope: scope) else {
            await afterTables?()
            return
        }
        if PluginManager.shared.databaseGroupingStrategy(for: connection.type) == .hierarchicalSchema {
            try await provider.withMetadataDriver(scope: scope) { [self] driver in
                guard await needsLoad(connectionId, scope: scope) else { return }
                _ = await runLoad(connectionId: connectionId, driver: driver, connection: connection, scope: scope)
            }
            await afterTables?()
            return
        }
        var started: LoadRun?
        defer {
            if let started { endRefresh(connectionId, generation: started.generation) }
        }
        // A load queued for the same lease finds the catalog the one ahead of it committed.
        let leased = try await provider.withMetadataRead(scope: scope, workload: .interactive) { [self] driver -> LoadRun? in
            guard await needsLoad(connectionId, scope: scope) else { return nil }
            var run = await beginLoad(connectionId: connectionId, driver: driver, connection: connection, scope: scope)
            let tables: Result<[TableInfo], any Error>
            do {
                tables = .success(try await readTables(run, driver: driver))
            } catch {
                tables = .failure(error)
            }
            run.tablesCommitted = await commitTables(tables, of: run, facts: CatalogDriverFacts(driver))
            return run
        }
        guard let run = leased else {
            await afterTables?()
            return
        }
        started = run
        guard let committed = run.tablesCommitted else { return }
        if committed {
            await afterTables?()
        }
        await readSideKinds(run, leasingFrom: provider, scope: scope)
    }

    func generationToken(for connectionId: UUID) -> Int {
        generations[connectionId] ?? 0
    }

    func isRefreshing(connectionId: UUID) -> Bool {
        refreshingConnections.contains(connectionId)
    }

    /// The schema list read with `database`'s catalog, for a reader that would otherwise read it again; nil when the
    /// catalog shown is another database's, is not current, or has no schema list.
    func currentSchemas(for connectionId: UUID, database: String) -> [String]? {
        guard let scope = loadedScope(for: connectionId), CatalogName.same(scope.database, database),
              isCatalogCurrent(for: connectionId)
        else { return nil }
        let schemas = schemas(for: connectionId)
        return schemas.isEmpty ? nil : schemas
    }

    func needsLoad(_ connectionId: UUID, scope: DatabaseScope?) -> Bool {
        guard case .loaded = state(for: connectionId) else { return true }
        return !((scope == nil || loadedScope(for: connectionId) == scope) && isCatalogCurrent(for: connectionId))
    }

    struct LoadRun: Sendable {
        let connectionId: UUID
        let key: CatalogKey
        let loadKey: LoadKey
        let scope: DatabaseScope?
        let type: DatabaseType
        let generation: Int
        let kinds: SideKinds
        let supportsSchemas: Bool
        let listsAttached: Bool
        // Nil when the load stops after its tables: cancelled, or overtaken by a newer one.
        var tablesCommitted: Bool?

        // A kind the engine does not list takes no lease.
        func reads(_ kind: SideKind) -> Bool {
            switch kind {
            case .schemas: return supportsSchemas || listsAttached
            case .routines: return true
            case .triggers: return kinds.triggers
            case .types: return kinds.types
            case .serverObjects: return !kinds.serverKindIds.isEmpty
            }
        }
    }

    struct SideReads: Sendable {
        var schemas: MetadataFetchOutcome<[String]>?
        var routines: MetadataFetchOutcome<[RoutineInfo]>?
        var triggers: MetadataFetchOutcome<[TriggerInfo]>?
        var types: MetadataFetchOutcome<[UserDefinedTypeInfo]>?
        var serverObjects: [String: MetadataFetchOutcome<[ServerObjectInfo]>] = [:]

        var failed: Bool {
            let fetched = [schemas?.didFetch, routines?.didFetch, triggers?.didFetch, types?.didFetch]
                + serverObjects.values.map(\.didFetch)
            return fetched.contains(false)
        }
    }

    func readTables(_ run: LoadRun, driver: DatabaseDriver) async throws -> [TableInfo] {
        let schema = run.scope?.schema
        return try await loadDedup.execute(key: run.loadKey) {
            try await driver.fetchTables(schema: schema)
        }
    }

    func readSideKinds(_ run: LoadRun, driver: DatabaseDriver) async -> SideReads {
        let schema = run.scope?.schema
        async let schemas = readSchemas(run, driver: driver)
        async let routines = readRoutines(run, driver: driver)
        async let triggers = readTriggers(run, driver: driver)
        async let types = readTypes(run, driver: driver)
        async let serverObjects = fetchServerObjectsSafely(
            kinds: run.kinds.serverKindIds,
            keys: Dictionary(uniqueKeysWithValues: run.kinds.serverKindIds.map {
                ($0, ServerObjectLoadKey(load: run.loadKey, kindId: $0))
            }),
            connectionId: run.connectionId,
            dedup: serverObjectsDedup,
            schema: schema,
            driver: driver
        )
        return await SideReads(
            schemas: schemas, routines: routines, triggers: triggers, types: types, serverObjects: serverObjects
        )
    }

    enum SideKind: CaseIterable {
        case schemas, routines, triggers, types, serverObjects
    }

    // A lease that cannot be had settles its kind and every later one, so no section waits on a read nothing runs.
    private func readSideKinds(
        _ run: LoadRun,
        leasingFrom provider: any ScopedMetadataProviding,
        scope: DatabaseScope
    ) async {
        let order = SideKind.allCases.filter { run.reads($0) }
        for (index, kind) in order.enumerated() {
            let reads: SideReads
            do {
                reads = try await provider.withMetadataRead(scope: scope, workload: .interactive) { [self] driver in
                    await readSideKind(kind, of: run, driver: driver)
                }
            } catch {
                settleUnreadKinds(Array(order[index...]), of: run, after: error)
                return
            }
            guard commitSideReads(reads, of: run) else { return }
        }
    }

    private func readSideKind(_ kind: SideKind, of run: LoadRun, driver: DatabaseDriver) async -> SideReads {
        var reads = SideReads()
        switch kind {
        case .schemas:
            reads.schemas = await readSchemas(run, driver: driver)
        case .routines:
            reads.routines = await readRoutines(run, driver: driver)
        case .triggers:
            reads.triggers = await readTriggers(run, driver: driver)
        case .types:
            reads.types = await readTypes(run, driver: driver)
        case .serverObjects:
            reads.serverObjects = await fetchServerObjectsSafely(
                kinds: run.kinds.serverKindIds,
                keys: Dictionary(uniqueKeysWithValues: run.kinds.serverKindIds.map {
                    ($0, ServerObjectLoadKey(load: run.loadKey, kindId: $0))
                }),
                connectionId: run.connectionId,
                dedup: serverObjectsDedup,
                schema: run.scope?.schema,
                driver: driver
            )
        }
        return reads
    }

    private func readSchemas(_ run: LoadRun, driver: DatabaseDriver) async -> MetadataFetchOutcome<[String]>? {
        guard run.supportsSchemas || run.listsAttached else { return nil }
        return await Self.fetchObjectsSafely(
            key: run.loadKey,
            connectionId: run.connectionId,
            label: "schemas",
            dedup: schemasDedup,
            fetch: { try await driver.fetchSchemas() }
        )
    }

    private func readRoutines(_ run: LoadRun, driver: DatabaseDriver) async -> MetadataFetchOutcome<[RoutineInfo]> {
        let schema = run.scope?.schema
        return await Self.fetchObjectsSafely(
            key: run.loadKey,
            connectionId: run.connectionId,
            label: "routines",
            dedup: routinesDedup,
            fetch: { try await driver.fetchRoutines(schema: schema) }
        )
    }

    private func readTriggers(_ run: LoadRun, driver: DatabaseDriver) async -> MetadataFetchOutcome<[TriggerInfo]>? {
        guard run.kinds.triggers else { return nil }
        let schema = run.scope?.schema
        return await Self.fetchObjectsSafely(
            key: run.loadKey,
            connectionId: run.connectionId,
            label: "triggers",
            dedup: triggersDedup,
            fetch: { try await driver.fetchAllTriggers(schema: schema) }
        )
    }

    private func readTypes(
        _ run: LoadRun,
        driver: DatabaseDriver
    ) async -> MetadataFetchOutcome<[UserDefinedTypeInfo]>? {
        guard run.kinds.types else { return nil }
        let schema = run.scope?.schema
        return await Self.fetchObjectsSafely(
            key: run.loadKey,
            connectionId: run.connectionId,
            label: "types",
            dedup: typesDedup,
            fetch: { try await driver.fetchUserDefinedTypes(schema: schema) }
        )
    }

    // One fetch per declared kind, side by side; each settles its own group.
    func fetchServerObjectsSafely<Key: Hashable & Sendable>(
        kinds: [String],
        keys: [String: Key],
        connectionId: UUID,
        dedup: OnceTask<Key, [ServerObjectInfo]>,
        schema: String?,
        driver: DatabaseDriver
    ) async -> [String: MetadataFetchOutcome<[ServerObjectInfo]>] {
        guard !kinds.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, MetadataFetchOutcome<[ServerObjectInfo]>)?.self) { group in
            for kindId in kinds {
                guard let key = keys[kindId] else { continue }
                group.addTask {
                    let outcome = await Self.fetchObjectsSafely(
                        key: key,
                        connectionId: connectionId,
                        label: "server objects",
                        dedup: dedup,
                        fetch: { try await driver.fetchServerObjects(ofKind: kindId, schema: schema) }
                    )
                    return (kindId, outcome)
                }
            }
            var outcomes: [String: MetadataFetchOutcome<[ServerObjectInfo]>] = [:]
            for await result in group {
                guard let result else { continue }
                outcomes[result.0] = result.1
            }
            return outcomes
        }
    }

    /// A failure comes back as a failure, never as an empty list. An empty list made a refresh that
    /// failed indistinguishable from a database with no routines, and the caller committed it over
    /// the loaded one: a single dropped connection emptied the sidebar's procedures and functions
    /// while the refresh reported success, with nothing scheduled to put them back.
    static func fetchObjectsSafely<Key: Hashable & Sendable, Value: Sendable>(
        key: Key,
        connectionId: UUID,
        label: String,
        dedup: OnceTask<Key, [Value]>,
        fetch: @Sendable @escaping () async throws -> [Value]
    ) async -> MetadataFetchOutcome<[Value]> {
        do {
            return .fetched(try await dedup.execute(key: key, work: fetch))
        } catch is CancellationError {
            return .cancelled
        } catch {
            logger.warning(
                "[schema] \(label, privacy: .public) load failed connId=\(connectionId, privacy: .public) error=\(error.publicLogShape, privacy: .public)"
            )
            return .failed(error.localizedDescription)
        }
    }
}
