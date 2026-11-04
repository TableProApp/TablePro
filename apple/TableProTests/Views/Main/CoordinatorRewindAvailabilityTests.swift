//
//  CoordinatorRewindAvailabilityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
struct CoordinatorRewindAvailabilityTests {
    private let storage: QueryHistoryStorage
    private let fixture: CoordinatorFixture
    private let cipher = RewindCipher(keychain: InMemoryKeychain())

    init() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coordinator-rewind-\(UUID().uuidString).db")
        storage = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
        let manager = QueryHistoryManager(storage: storage, isCapturePaused: { false })
        fixture = CoordinatorFixture(services: AppServices.live.replacingQueryHistory(manager))
        fixture.addTab(QueryTab(title: "users", query: "SELECT * FROM users", tabType: .table, tableName: "users"))
    }

    private var coordinator: MainContentCoordinator { fixture.coordinator }

    private func makeRecord(table: String, historyId: UUID? = nil) throws -> RewindRecord {
        let scope = try #require(coordinator.selectedTabScope)
        let target = DataWriteTarget(database: scope.database, schema: scope.schema, table: table)
        return RewindRecord(
            id: UUID(),
            historyId: historyId,
            connectionId: fixture.connection.id,
            databaseType: fixture.connection.type,
            target: target,
            capturedAt: Date(),
            generatedColumns: [],
            identityColumns: [],
            operations: [
                RowWriteOperation(
                    kind: .update,
                    target: target,
                    columns: ["id", "name"],
                    primaryKeyColumns: ["id"],
                    preImage: ["7", "Ada"],
                    postImage: ["7", "Grace"],
                    writtenColumns: ["name"],
                    refusal: nil
                ),
            ]
        )
    }

    @Test("Restore Previous Values stays off until the selected table has a kept save")
    func offUntilASaveIsKept() async throws {
        let cache = coordinator.services.queryHistoryManager.rewindAvailability
        try await waitUntil { cache.availability.revision >= 0 }
        #expect(!coordinator.canRewindSelectedTab)

        await storage.recordRewindSnapshot(try makeRecord(table: "orders"), cipher: cipher)
        try await waitUntil { cache.availability.targets.count == 1 }
        #expect(!coordinator.canRewindSelectedTab)

        let kept = try makeRecord(table: "users")
        await storage.recordRewindSnapshot(kept, cipher: cipher)
        try await waitUntil { coordinator.canRewindSelectedTab }

        await storage.deleteRewindSnapshot(id: kept.id)
        try await waitUntil { !coordinator.canRewindSelectedTab }
    }

    @Test("The drawer's Restore Previous Values follows its own save, not the selected table")
    func drawerFollowsItsOwnSave() async throws {
        let historyId = UUID()
        let cache = coordinator.services.queryHistoryManager.rewindAvailability
        try await waitUntil { cache.availability.revision >= 0 }
        #expect(await storage.record(TestFixtures.makeHistoryEntry(
            id: historyId, connectionId: fixture.connection.id, source: .rowEdit
        )))
        #expect(!coordinator.canRestoreSave(historyId: historyId))

        #expect(await storage.recordRewindSnapshot(try makeRecord(table: "orders", historyId: historyId), cipher: cipher))
        try await waitUntil { coordinator.canRestoreSave(historyId: historyId) }
        #expect(!coordinator.canRewindSelectedTab)
    }
}

@MainActor
private extension AppServices {
    func replacingQueryHistory(_ manager: QueryHistoryManager) -> AppServices {
        AppServices(
            appEvents: appEvents,
            appSettings: appSettings,
            appSettingsStorage: appSettingsStorage,
            connectionStorage: connectionStorage,
            databaseManager: databaseManager,
            pluginManager: pluginManager,
            schemaService: schemaService,
            schemaRefreshService: schemaRefreshService,
            schemaProviderRegistry: schemaProviderRegistry,
            catalogChangeService: catalogChangeService,
            sqlFavoriteManager: sqlFavoriteManager,
            favoriteTablesStorage: favoriteTablesStorage,
            favoriteDatabasesStorage: favoriteDatabasesStorage,
            tableFolderStorage: tableFolderStorage,
            aiChatStorage: aiChatStorage,
            aiKeyStorage: aiKeyStorage,
            aiAccessApprovals: aiAccessApprovals,
            groupStorage: groupStorage,
            tagStorage: tagStorage,
            sshProfileStorage: sshProfileStorage,
            credentialProfileStorage: credentialProfileStorage,
            licenseManager: licenseManager,
            syncMetadataStorage: syncMetadataStorage,
            favoritesExpansionState: favoritesExpansionState,
            linkedFolderWatcher: linkedFolderWatcher,
            queryHistoryManager: manager,
            dateFormattingService: dateFormattingService,
            copilotService: copilotService,
            mcpServerManager: mcpServerManager,
            syncTracker: syncTracker,
            welcomeRouter: welcomeRouter
        )
    }
}
