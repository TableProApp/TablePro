//
//  ConnectionCatalogSnapshot.swift
//  TablePro
//

import Combine
import Foundation

// The services key every list by connection, so observing them re-rendered every window on any connection's load.
@MainActor
final class ConnectionCatalogSnapshot: ObservableObject {
    @Published private(set) var tables: [TableInfo]
    @Published private(set) var schemas: [String]
    @Published private(set) var isRefreshing: Bool
    @Published private(set) var databases: [DatabaseMetadata]

    let connectionId: UUID
    private let schemaService: SchemaService
    private let treeService: DatabaseTreeMetadataService
    private var observations: [AnyCancellable] = []

    init(connectionId: UUID, schemaService: SchemaService, treeService: DatabaseTreeMetadataService) {
        self.connectionId = connectionId
        self.schemaService = schemaService
        self.treeService = treeService
        tables = schemaService.tables(for: connectionId)
        schemas = schemaService.schemas(for: connectionId)
        isRefreshing = schemaService.isRefreshing(connectionId: connectionId)
        databases = treeService.databases(for: connectionId)
        observations = [
            schemaService.onMainActorChange { [weak self] in self?.readSchemaService() },
            treeService.onMainActorChange { [weak self] in self?.readTreeService() }
        ]
    }

    // Each write is guarded: an unguarded @Published write publishes an equal value too.
    private func readSchemaService() {
        let tables = schemaService.tables(for: connectionId)
        if tables != self.tables { self.tables = tables }
        let schemas = schemaService.schemas(for: connectionId)
        if schemas != self.schemas { self.schemas = schemas }
        let isRefreshing = schemaService.isRefreshing(connectionId: connectionId)
        if isRefreshing != self.isRefreshing { self.isRefreshing = isRefreshing }
    }

    private func readTreeService() {
        let databases = treeService.databases(for: connectionId)
        if databases != self.databases { self.databases = databases }
    }
}
