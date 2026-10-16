//
//  SyncCoordinatorThemeTests.swift
//  TableProTests
//
//  Themes ride the AppSettings record type as `theme.<id>`, next to the `appearance` record that
//  selects them. The Auto, Light or Dark mode no longer rides along: each Mac keeps its own.
//

import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import TableProTestSupport
import TableProTheme
import Testing

@MainActor
struct SyncCoordinatorThemeTests {
    @MainActor
    private final class Harness {
        let environment: SyncTestEnvironment
        let transport: ScriptedSyncTransport
        let themes: URL
        let catalog: ThemeCatalog
        let engine: ThemeEngine
        let storage: AppSettingsStorage
        let settings: AppSettingsManager
        let coordinator: SyncCoordinator

        var tracker: SyncChangeTracker { environment.tracker }
        var metadata: SyncMetadataStorage { environment.metadata }

        init(
            label: String,
            themesDirectory: URL? = nil,
            pulled: @escaping @Sendable ([CKRecord]) -> PullResult = { _ in
                PullResult(changedRecords: [], deletedRecordIDs: [], newToken: nil)
            }
        ) throws {
            let environment = try SyncTestEnvironment(label: label)
            let transport = ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID, pulled: pulled)
            self.environment = environment
            self.transport = transport
            themes = themesDirectory ?? environment.directory.appendingPathComponent("Themes", isDirectory: true)
            let trash = environment.directory.appendingPathComponent("Trash", isDirectory: true)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            catalog = ThemeCatalog(
                userDirectory: themes,
                bundleDirectory: nil,
                notificationCenter: NotificationCenter(),
                fileTrash: .folder(trash),
                syncTracker: environment.tracker
            )
            engine = ThemeEngine(catalog: catalog)
            storage = AppSettingsStorage(userDefaults: environment.defaults)
            settings = AppSettingsManager(
                storage: storage,
                themeEngine: engine,
                syncTracker: environment.tracker,
                appEvents: AppEvents()
            )
            let base = environment.makeCoordinator(transport: transport)
            let columnLayouts = environment.columnLayouts
            coordinator = SyncCoordinator(
                services: base.services.replacing(appSettings: settings, storage: storage, themeEngine: engine),
                recordCache: environment.recordCache,
                transport: transport,
                makeNetworkMonitor: { nil },
                columnLayouts: columnLayouts,
                themeCatalog: catalog,
                licenseGate: { nil }
            )
        }

        func setSync(_ enabled: Bool) {
            var sync = SyncSettings.default
            sync.enabled = enabled
            storage.saveSync(sync)
        }

        func writeOnDisk(_ theme: ThemeDefinition) throws {
            try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
            try ThemeFileFormat.encode(theme).write(to: themes.appendingPathComponent("\(theme.id).json"))
            catalog.reloadSynchronously()
        }

        func fileExists(_ id: String) -> Bool {
            FileManager.default.fileExists(atPath: themes.appendingPathComponent("\(id).json").path)
        }
    }

    nonisolated private static func theme(_ id: String, background: String = "#224466") throws -> ThemeDefinition {
        ThemeDefinition(
            id: id,
            name: id,
            author: "",
            appearance: .dark,
            overrides: [.editorBackground: try ThemeColor(validating: background)]
        )
    }

    private static func themeRecord(_ theme: ThemeDefinition) throws -> CKRecord {
        SyncRecordMapper.toCKRecord(
            category: ThemeCatalog.syncCategory(for: theme.id),
            settingsData: try ThemeFileFormat.encode(theme),
            in: SyncTestEnvironment.zoneID
        )
    }

    private static func settingsRecord(_ category: String, json: String) -> CKRecord {
        SyncRecordMapper.toCKRecord(category: category, settingsData: Data(json.utf8), in: SyncTestEnvironment.zoneID)
    }

    private static func deletion(ofTheme id: String) -> CKRecord.ID {
        CKRecord.ID(
            recordName: SyncRecordType.settings.recordName(for: ThemeCatalog.syncCategory(for: id)),
            zoneID: SyncTestEnvironment.zoneID
        )
    }

    private static func pull(_ records: [CKRecord], deleting deletions: [CKRecord.ID] = []) -> PullResult {
        PullResult(changedRecords: records, deletedRecordIDs: deletions, newToken: nil)
    }

    // MARK: - Arrival

    @Test("A pulled theme lands on disk and reaches the windows, whichever record comes first", arguments: [true, false])
    func pulledThemeReachesTheEngine(themeFirst: Bool) async throws {
        let harness = try Harness(label: "theme-arrival")
        let synced = try Self.theme("user.synced")
        let selection = Self.settingsRecord(
            AppSettingsCategory.appearance,
            json: #"{"preferredLightThemeId":"tablepro.default-light","preferredDarkThemeId":"user.synced"}"#
        )
        let records = themeFirst ? [try Self.themeRecord(synced), selection] : [selection, try Self.themeRecord(synced)]

        let acknowledged = await harness.coordinator.applyPullResult(Self.pull(records))

        #expect(acknowledged)
        try await waitUntil { harness.engine.pair.dark == synced }
        #expect(harness.settings.appearance.preferredDarkThemeId == synced.id)
        #expect(harness.fileExists(synced.id))
        #expect(harness.tracker.dirtyRecords(for: .settings).isEmpty)
    }

    @Test("A theme record that fails validation is skipped, and the pull is still acknowledged")
    func invalidThemeIsSkipped() async throws {
        let harness = try Harness(label: "theme-invalid")
        let mismatched = SyncRecordMapper.toCKRecord(
            category: ThemeCatalog.syncCategory(for: "user.claimed"),
            settingsData: try ThemeFileFormat.encode(try Self.theme("user.other")),
            in: SyncTestEnvironment.zoneID
        )

        let acknowledged = await harness.coordinator.applyPullResult(Self.pull([mismatched]))

        #expect(acknowledged)
        #expect(!harness.fileExists("user.claimed"))
        #expect(!harness.fileExists("user.other"))
    }

    @Test("A theme the disk refused withholds the change token, so the record arrives again")
    func diskFailureWithholdsTheToken() async throws {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncCoordinatorThemeTests-blocker-\(UUID().uuidString)")
        #expect(FileManager.default.createFile(atPath: blocker.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: blocker) }
        let harness = try Harness(label: "theme-disk", themesDirectory: blocker.appendingPathComponent("Themes"))
        let token = try Self.makeChangeToken()

        let acknowledged = await harness.coordinator.applyPullResult(
            PullResult(changedRecords: [try Self.themeRecord(try Self.theme("user.synced"))], deletedRecordIDs: [], newToken: token)
        )

        #expect(!acknowledged)
        #expect(harness.metadata.loadToken() == nil)
    }

    // MARK: - Deletion

    @Test("A theme deleted on another Mac leaves this one, with no tombstone sent back")
    func pulledDeletionRemovesTheTheme() async throws {
        let harness = try Harness(label: "theme-deletion")
        let night = try Self.theme("user.night")
        try harness.writeOnDisk(night)
        harness.engine.select(lightThemeId: BuiltInThemes.defaultLightId, darkThemeId: night.id)
        #expect(harness.engine.pair.dark == night)

        let acknowledged = await harness.coordinator.applyPullResult(Self.pull([], deleting: [Self.deletion(ofTheme: night.id)]))

        #expect(acknowledged)
        #expect(harness.catalog.theme(id: night.id) == nil)
        #expect(!harness.fileExists(night.id))
        #expect(harness.tracker.tombstonedIds(for: .settings).isEmpty)
        try await waitUntil { harness.engine.pair.dark == BuiltInThemes.dark }
    }

    @Test("A theme this Mac moved to the Trash stays gone when an edit of it arrives")
    func localTombstoneBeatsARemoteEdit() async throws {
        let harness = try Harness(label: "theme-tombstone")
        let night = try Self.theme("user.night")
        try harness.writeOnDisk(night)
        try harness.catalog.trash(id: night.id)
        #expect(harness.tracker.tombstonedIds(for: .settings) == [ThemeCatalog.syncCategory(for: night.id)])

        let edited = try Self.theme("user.night", background: "#336699")
        let acknowledged = await harness.coordinator.applyPullResult(Self.pull([try Self.themeRecord(edited)]))

        #expect(acknowledged)
        #expect(harness.catalog.theme(id: night.id) == nil)
        #expect(!harness.fileExists(night.id))
    }

    // MARK: - Push

    @Test("A theme's outgoing record is its canonical file, and a trashed one is pushed as a deletion")
    func pushCarriesThemesAndTheirDeletions() async throws {
        let harness = try Harness(label: "theme-push")
        let night = try Self.theme("user.night")
        try harness.catalog.save(night)
        let category = ThemeCatalog.syncCategory(for: night.id)

        let canonical = try ThemeFileFormat.encode(night)
        #expect(harness.coordinator.settingsData(for: category) == canonical)
        #expect(await harness.coordinator.runSyncCycle() == nil)
        let pushed = await harness.transport.pushedRecords
        #expect(pushed.contains { SyncRecordMapper.settingsCategory(from: $0) == category })
        #expect(harness.tracker.dirtyRecords(for: .settings).isEmpty)

        try harness.catalog.trash(id: night.id)
        #expect(await harness.coordinator.runSyncCycle() == nil)
        let deletions = await harness.transport.pushedDeletions
        #expect(deletions.contains(Self.deletion(ofTheme: night.id)))
        #expect(harness.tracker.tombstonedIds(for: .settings).isEmpty)
    }

    @Test("Turning sync on marks every theme on this Mac")
    func enablingSyncMarksThemes() throws {
        let harness = try Harness(label: "theme-enable")
        try harness.writeOnDisk(try Self.theme("user.night"))
        try harness.writeOnDisk(try Self.theme("user.day"))
        #expect(harness.tracker.dirtyRecords(for: .settings).isEmpty)
        harness.setSync(true)

        harness.coordinator.enableSync()

        let dirty = harness.tracker.dirtyRecords(for: .settings)
        #expect(dirty.isSuperset(of: [ThemeCatalog.syncCategory(for: "user.night"), ThemeCatalog.syncCategory(for: "user.day")]))
    }

    // MARK: - Late upgraders

    @Test("A build that reads themes, or a newer theme format, fetches the zone once")
    func themeContentKindGrowsTheReadableSet() throws {
        let suite = try EphemeralDefaults()
        let metadata = SyncMetadataStorage(userDefaults: suite.defaults)
        let types = Set(SyncRecordType.verifiedInProduction.map(\.rawValue))
        _ = metadata.adoptReadableRecordTypes(types)

        #expect(SyncCoordinator.readableContent.contains(SyncCoordinator.themeContentKind))
        #expect(SyncCoordinator.themeContentKind == "AppSettings/theme.v\(ThemeSchema.current)")
        #expect(metadata.adoptReadableRecordTypes(SyncCoordinator.readableContent))
        #expect(!metadata.adoptReadableRecordTypes(SyncCoordinator.readableContent))
        #expect(metadata.adoptReadableRecordTypes(types.union(["AppSettings/theme.v\(ThemeSchema.current + 1)"])))
    }

    @Test("The first launch of a theme-syncing build clears the change token, and the next one keeps it")
    func firstThemeBuildClearsTheToken() async throws {
        let harness = try Harness(label: "theme-token")
        #expect(harness.environment.connections.saveConnections([DatabaseConnection(name: "Local")]))
        _ = harness.metadata.adoptReadableRecordTypes(Set(SyncRecordType.verifiedInProduction.map(\.rawValue)))
        harness.metadata.saveToken(try Self.makeChangeToken())
        harness.setSync(true)

        harness.coordinator.start()
        #expect(harness.metadata.loadToken() == nil)
        try await waitUntil { await harness.transport.pullCount == 1 && harness.coordinator.syncStatus != .syncing }

        harness.metadata.saveToken(try Self.makeChangeToken())
        let columnLayouts = harness.environment.columnLayouts
        let relaunched = SyncCoordinator(
            services: harness.coordinator.services,
            recordCache: harness.environment.recordCache,
            transport: ScriptedSyncTransport(zoneID: SyncTestEnvironment.zoneID),
            makeNetworkMonitor: { nil },
            columnLayouts: columnLayouts,
            themeCatalog: harness.catalog,
            licenseGate: { nil }
        )
        relaunched.start()
        #expect(harness.metadata.loadToken() != nil)
    }

    @Test("After the first full pull, only the themes the server lacks are uploaded, and only once")
    func seedMarksOnlyWhatTheServerLacks() async throws {
        let held = try Self.theme("user.held")
        let heldRecord = try Self.themeRecord(held)
        let harness = try Harness(label: "theme-seed") { _ in
            PullResult(changedRecords: [heldRecord], deletedRecordIDs: [], newToken: nil)
        }
        #expect(harness.environment.connections.saveConnections([DatabaseConnection(name: "Local")]))
        try harness.writeOnDisk(held)
        try harness.writeOnDisk(try Self.theme("user.local"))
        let localCategory = ThemeCatalog.syncCategory(for: "user.local")
        #expect(harness.tracker.dirtyRecords(for: .settings).isEmpty)
        harness.setSync(true)

        harness.coordinator.start()
        #expect(harness.metadata.themeSeedState == .pending)
        try await waitUntil { harness.metadata.themeSeedState == .done && harness.coordinator.syncStatus != .syncing }
        #expect(harness.tracker.dirtyRecords(for: .settings) == [localCategory])

        await harness.coordinator.syncNow()

        let pushed = await harness.transport.pushedRecords
        #expect(pushed.contains { SyncRecordMapper.settingsCategory(from: $0) == localCategory })
        #expect(!pushed.contains { SyncRecordMapper.settingsCategory(from: $0) == ThemeCatalog.syncCategory(for: held.id) })
        #expect(harness.tracker.dirtyRecords(for: .settings).isEmpty)
    }

    @Test("The first full pull keeps a never-synced local theme that differs from the record, and the seed uploads it")
    func firstFullPullKeepsADifferingLocalTheme() async throws {
        let remote = try Self.theme("user.x", background: "#336699")
        let remoteRecord = try Self.themeRecord(remote)
        let harness = try Harness(label: "theme-seed-conflict") { _ in
            PullResult(changedRecords: [remoteRecord], deletedRecordIDs: [], newToken: nil)
        }
        #expect(harness.environment.connections.saveConnections([DatabaseConnection(name: "Local")]))
        let local = try Self.theme("user.x", background: "#224466")
        try harness.writeOnDisk(local)
        harness.setSync(true)

        harness.coordinator.start()
        try await waitUntil { harness.metadata.themeSeedState == .done && harness.coordinator.syncStatus != .syncing }

        #expect(harness.catalog.storedTheme(id: remote.id) == remote)
        let kept = try #require(harness.catalog.themes.first { !$0.isBuiltIn && $0.id != remote.id })
        #expect(kept.overrides == local.overrides)
        #expect(harness.tracker.dirtyRecords(for: .settings) == [ThemeCatalog.syncCategory(for: kept.id)])
    }

    @Test("Once the seed ran, a pulled edit replaces the local file and keeps no copy")
    func seededPullReplacesTheLocalTheme() async throws {
        let harness = try Harness(label: "theme-seeded-edit")
        try harness.writeOnDisk(try Self.theme("user.x", background: "#224466"))
        harness.metadata.themeSeedState = .done
        let remote = try Self.theme("user.x", background: "#336699")

        let acknowledged = await harness.coordinator.applyPullResult(Self.pull([try Self.themeRecord(remote)]))

        #expect(acknowledged)
        #expect(harness.catalog.themes.filter { !$0.isBuiltIn } == [remote])
    }

    // MARK: - Appearance mode

    @Test("An appearance record from an older Mac changes the theme ids and leaves this Mac's mode alone")
    func olderPeerPayloadKeepsTheLocalMode() async throws {
        let harness = try Harness(label: "theme-mode-in")
        #expect(harness.settings.appearanceMode == .auto)
        let legacy = Self.settingsRecord(
            AppSettingsCategory.appearance,
            json: #"{"appearanceMode":"dark","preferredLightThemeId":"user.day","preferredDarkThemeId":"user.night"}"#
        )

        let acknowledged = await harness.coordinator.applyPullResult(Self.pull([legacy]))

        #expect(acknowledged)
        #expect(harness.settings.appearance == AppearanceSettings(preferredLightThemeId: "user.day", preferredDarkThemeId: "user.night"))
        #expect(harness.settings.appearanceMode == .auto)
        #expect(harness.storage.loadAppearanceMode() == .auto)
        #expect(harness.engine.mode == .auto)
    }

    @Test("The outgoing appearance record carries the theme ids and no mode")
    func outgoingPayloadCarriesNoMode() throws {
        let harness = try Harness(label: "theme-mode-out")
        harness.storage.saveAppearance(AppearanceSettings(preferredLightThemeId: "user.day", preferredDarkThemeId: "user.night"))
        harness.storage.saveAppearanceMode(.dark)

        let data = try #require(harness.coordinator.settingsData(for: AppSettingsCategory.appearance))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["preferredLightThemeId", "preferredDarkThemeId"])
        #expect(object["preferredDarkThemeId"] as? String == "user.night")
    }

    // MARK: - Fixtures

    private static func makeChangeToken() throws -> CKServerChangeToken {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName("CKServerChangeToken", for: ThemeSyncChangeTokenArchive.self)
        archiver.encode(ThemeSyncChangeTokenArchive(), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        let token = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: archiver.encodedData)
        return try #require(token)
    }
}

@objc(SyncCoordinatorThemeTestsChangeTokenArchive)
private final class ThemeSyncChangeTokenArchive: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    override init() {
        super.init()
    }

    required init?(coder: NSCoder) {
        super.init()
    }

    func encode(with coder: NSCoder) {}
}

@MainActor
private extension AppServices {
    func replacing(appSettings: AppSettingsManager, storage: AppSettingsStorage, themeEngine: ThemeEngine) -> AppServices {
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
            licenseManager: licenseManager,
            syncMetadataStorage: syncMetadataStorage,
            favoritesExpansionState: favoritesExpansionState,
            linkedFolderWatcher: linkedFolderWatcher,
            queryHistoryManager: queryHistoryManager,
            dateFormattingService: dateFormattingService,
            copilotService: copilotService,
            mcpServerManager: mcpServerManager,
            syncTracker: syncTracker,
            themeEngine: themeEngine,
            welcomeRouter: welcomeRouter
        )
    }
}
