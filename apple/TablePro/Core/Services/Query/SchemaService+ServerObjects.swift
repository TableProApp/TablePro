//
//  SchemaService+ServerObjects.swift
//  TablePro
//

import Foundation

extension SchemaService {
    func serverObjects(for connectionId: UUID, kindId: String) -> [ServerObjectInfo] {
        serverObjectsLoadState(for: connectionId, kindId: kindId).value ?? []
    }

    func serverObjectsLoadState(for connectionId: UUID, kindId: String) -> MetadataLoadState<[ServerObjectInfo]> {
        sideObjects[shownKey(connectionId)]?.serverObjects[kindId] ?? .idle
    }

    func serverObjectStates(for connectionId: UUID) -> [String: MetadataLoadState<[ServerObjectInfo]>] {
        sideObjects[shownKey(connectionId)]?.serverObjects ?? [:]
    }

    func serverObjects(for connectionId: UUID, schema: String, kindId: String) -> [ServerObjectInfo] {
        serverObjectsLoadState(for: connectionId, schema: schema, kindId: kindId).value ?? []
    }

    func serverObjectsByKind(for connectionId: UUID, schema: String) -> [String: [ServerObjectInfo]] {
        (perSchemaSideObjects[catalogKey(connectionId, schema: schema)]?.serverObjects ?? [:]).compactMapValues(\.value)
    }

    func serverObjectsLoadState(
        for connectionId: UUID,
        schema: String,
        kindId: String
    ) -> MetadataLoadState<[ServerObjectInfo]> {
        perSchemaSideObjects[catalogKey(connectionId, schema: schema)]?.serverObjects[kindId] ?? .idle
    }

    @discardableResult
    func reloadServerObjects(
        connectionId: UUID,
        driver: DatabaseDriver,
        scope: DatabaseScope?,
        kindId: String
    ) async -> Bool {
        let key = reloadKey(connectionId, scope: scope, driver: driver)
        updateSideObjects(key) { $0.serverObjects[kindId] = ($0.serverObjects[kindId] ?? .idle).enteringLoad }
        bumpGeneration(connectionId)
        let outcome = await Self.fetchObjectsSafely(
            key: ServerObjectLoadKey(load: LoadKey(connectionId: connectionId, scope: scope), kindId: kindId),
            connectionId: connectionId,
            label: "server objects",
            dedup: serverObjectsDedup,
            fetch: { try await driver.fetchServerObjects(ofKind: kindId, schema: nil) }
        )
        updateKeptSideObjects(key) {
            $0.serverObjects[kindId] = ($0.serverObjects[kindId] ?? .idle).settled(by: outcome, discardingValue: false)
        }
        bumpGeneration(connectionId)
        return outcome.didFetch
    }
}
