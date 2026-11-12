//
//  AppSettingsValueColorsTests.swift
//  TableProTests
//

import CloudKit
import Combine
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct AppSettingsValueColorsTests {
    @MainActor
    private final class Harness {
        let environment: SyncTestEnvironment
        let storage: AppSettingsStorage
        let settings: AppSettingsManager
        let coordinator: SyncCoordinator
        private(set) var sentEvents = 0
        private var subscription: AnyCancellable?

        var tracker: SyncChangeTracker { environment.tracker }

        init(label: String, saved: ValueColorSettings? = nil) throws {
            let environment = try SyncTestEnvironment(label: label)
            let storage = AppSettingsStorage(userDefaults: environment.defaults)
            if let saved { storage.saveValueColors(saved) }
            let events = AppEvents()
            let catalog = ThemeCatalog(
                userDirectory: environment.directory.appendingPathComponent("Themes", isDirectory: true),
                bundleDirectory: nil,
                fileTrash: .folder(environment.directory.appendingPathComponent("Trash", isDirectory: true)),
                syncTracker: environment.tracker
            )
            let settings = AppSettingsManager(
                storage: storage,
                themeEngine: ThemeEngine(catalog: catalog),
                syncTracker: environment.tracker,
                appEvents: events
            )
            let transport = ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID)
            let columnLayouts = environment.columnLayouts
            let base = environment.makeCoordinator(transport: transport)
            self.environment = environment
            self.storage = storage
            self.settings = settings
            coordinator = SyncCoordinator(
                services: base.services.withAppSettings(settings, storage: storage),
                recordCache: environment.recordCache,
                transport: transport,
                makeNetworkMonitor: { nil },
                columnLayouts: columnLayouts,
                themeCatalog: catalog,
                licenseGate: { nil }
            )
            subscription = events.valueColorSettingsChanged.sink { [weak self] in self?.sentEvents += 1 }
        }

        func pull(_ category: String, _ data: Data) async -> Bool {
            let record = SyncRecordMapper.toCKRecord(category: category, settingsData: data, in: SyncTestEnvironment.zoneID)
            return await coordinator.applyPullResult(PullResult(changedRecords: [record], deletedRecordIDs: [], newToken: nil))
        }
    }

    // MARK: - Manager

    @Test("Turning Color values by type on saves it, tells the open grids and marks its record for sync")
    func changeSavesSendsAndMarks() throws {
        let harness = try Harness(label: "value-colors-change")

        harness.settings.valueColors = ValueColorSettings(colorsValuesByType: true)

        #expect(harness.storage.loadValueColors().colorsValuesByType)
        #expect(harness.sentEvents == 1)
        #expect(harness.tracker.dirtyRecords(for: .settings) == [AppSettingsCategory.valueColors])
    }

    @Test("Writing the value colors it already holds tells no grid and marks nothing")
    func unchangedWriteDoesNothing() throws {
        let harness = try Harness(label: "value-colors-same", saved: ValueColorSettings(colorsValuesByType: true))

        harness.settings.valueColors = ValueColorSettings(colorsValuesByType: true)

        #expect(harness.sentEvents == 0)
        #expect(harness.tracker.dirtyRecords(for: .settings).isEmpty)
    }

    // MARK: - Sync

    @Test("The outgoing value colors record carries what this Mac saved")
    func outgoingRecordCarriesTheSavedSetting() throws {
        let harness = try Harness(label: "value-colors-out", saved: ValueColorSettings(colorsValuesByType: true))

        let data = try #require(harness.coordinator.settingsData(for: AppSettingsCategory.valueColors))

        #expect(try JSONDecoder().decode(ValueColorSettings.self, from: data) == ValueColorSettings(colorsValuesByType: true))
    }

    @Test("A pulled value colors record turns the setting on and recolors the grids, without marking it for push")
    func pulledRecordAppliesWithoutMarking() async throws {
        let harness = try Harness(label: "value-colors-in")
        let data = try JSONEncoder().encode(ValueColorSettings(colorsValuesByType: true))

        let acknowledged = await harness.pull(AppSettingsCategory.valueColors, data)

        #expect(acknowledged)
        #expect(harness.settings.valueColors.colorsValuesByType)
        #expect(harness.storage.loadValueColors().colorsValuesByType)
        #expect(harness.sentEvents == 1)
        #expect(harness.tracker.dirtyRecords(for: .settings).isEmpty)
    }

    @Test("A Data Grid record from a Mac that predates value colors leaves them as they are")
    func olderDataGridRecordKeepsValueColors() async throws {
        let harness = try Harness(label: "value-colors-older-grid", saved: ValueColorSettings(colorsValuesByType: true))
        var dataGrid = DataGridSettings.default
        dataGrid.showRowNumbers.toggle()

        let acknowledged = await harness.pull(AppSettingsCategory.dataGrid, try JSONEncoder().encode(dataGrid))

        #expect(acknowledged)
        #expect(harness.settings.dataGrid.showRowNumbers == dataGrid.showRowNumbers)
        #expect(harness.settings.valueColors.colorsValuesByType)
        #expect(harness.storage.loadValueColors().colorsValuesByType)
        #expect(harness.sentEvents == 0)
    }
}

@MainActor
private extension AppServices {
    func withAppSettings(_ appSettings: AppSettingsManager, storage: AppSettingsStorage) -> AppServices {
        AppServices(
            appEvents: appEvents,
            appSettings: appSettings,
            appSettingsStorage: storage,
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
            featureAccess: featureAccess,
            syncMetadataStorage: syncMetadataStorage,
            favoritesExpansionState: favoritesExpansionState,
            linkedFolderWatcher: linkedFolderWatcher,
            queryHistoryManager: queryHistoryManager,
            dateFormattingService: dateFormattingService,
            copilotService: copilotService,
            mcpServerManager: mcpServerManager,
            syncTracker: syncTracker,
            welcomeRouter: welcomeRouter,
            telemetry: telemetry
        )
    }
}
