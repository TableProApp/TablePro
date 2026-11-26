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
    // the whole catalog. The tables lease opens before any state moves: a refused lease leaves it untouched.
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
        let leased = try await provider.withMetadataDriver(scope: scope) { [self] driver -> LoadRun? in
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

    // One call for every side kind, so an engine that answers several catalog reads in one round trip pays one
    // instead of one per kind. A load and a refresh of the same catalog share the read.
    func readSideKinds(_ run: LoadRun, driver: DatabaseDriver) async -> SideReads {
        let request = CatalogSideRequest(
            schema: run.scope?.schema,
            schemas: run.reads(.schemas),
            routines: run.reads(.routines),
            triggers: run.reads(.triggers),
            userDefinedTypes: run.reads(.types),
            serverObjectKinds: run.reads(.serverObjects) ? run.kinds.serverKindIds : []
        )
        let answers: CatalogSideObjects
        do {
            answers = try await sideObjectsDedup.execute(key: run.loadKey) {
                await driver.fetchCatalogSideObjects(request)
            }
        } catch {
            return SideReads(cancelled: request)
        }
        let connectionId = run.connectionId
        var reads = SideReads()
        reads.schemas = answers.schemas.map { Self.outcome($0, label: "schemas", connectionId: connectionId) }
        reads.routines = answers.routines.map { Self.outcome($0, label: "routines", connectionId: connectionId) }
        reads.triggers = answers.triggers.map { Self.outcome($0, label: "triggers", connectionId: connectionId) }
        reads.types = answers.userDefinedTypes.map { Self.outcome($0, label: "types", connectionId: connectionId) }
        for (kindId, answer) in answers.serverObjects {
            reads.serverObjects[kindId] = Self.outcome(answer, label: "server objects", connectionId: connectionId)
        }
        return reads
    }

    enum SideKind: CaseIterable {
        case schemas, routines, triggers, types, serverObjects
    }

    // One lease for every side kind, which the driver may answer in one round trip. A column read asked for meanwhile
    // waits that one read rather than the whole catalog. A lease that cannot be had settles every kind, so no section
    // waits on a read nothing runs.
    private func readSideKinds(
        _ run: LoadRun,
        leasingFrom provider: any ScopedMetadataProviding,
        scope: DatabaseScope
    ) async {
        let order = SideKind.allCases.filter { run.reads($0) }
        guard !order.isEmpty else { return }
        let reads: SideReads
        do {
            reads = try await provider.withMetadataDriver(scope: scope) { [self] driver in
                await readSideKinds(run, driver: driver)
            }
        } catch {
            settleUnreadKinds(order, of: run, after: error)
            return
        }
        _ = commitSideReads(reads, of: run)
    }

    // As `fetchObjectsSafely` settles a single read: a failure stays a failure, never an empty list.
    private static func outcome<Value: Sendable>(
        _ answer: Result<Value, any Error>,
        label: String,
        connectionId: UUID
    ) -> MetadataFetchOutcome<Value> {
        switch answer {
        case .success(let value):
            return .fetched(value)
        case .failure(let error) where error is CancellationError:
            return .cancelled
        case .failure(let error):
            logger.warning(
                "[schema] \(label, privacy: .public) load failed connId=\(connectionId, privacy: .public) error=\(error.publicLogShape, privacy: .public)"
            )
            return .failed(error.localizedDescription)
        }
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

extension SchemaService.SideReads {
    // Every kind the request asked, settled as cancelled: a shared read that was called off answered none of them.
    init(cancelled request: CatalogSideRequest) {
        self.init()
        if request.schemas { schemas = .cancelled }
        if request.routines { routines = .cancelled }
        if request.triggers { triggers = .cancelled }
        if request.userDefinedTypes { types = .cancelled }
        for kindId in request.serverObjectKinds {
            serverObjects[kindId] = .cancelled
        }
    }
}
