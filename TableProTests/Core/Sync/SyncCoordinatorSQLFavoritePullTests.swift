//
//  SyncCoordinatorSQLFavoritePullTests.swift
//  TableProTests
//

import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct SyncCoordinatorSQLFavoritePullTests {
    private static let zoneID = CKRecordZone.ID(
        zoneName: CloudKitSyncEngine.zoneName,
        ownerName: CKCurrentUserDefaultName
    )

    private let connectionId = UUID()
    private let defaults: UserDefaults
    private let metadata: SyncMetadataStorage
    private let tracker: SyncChangeTracker
    private let recordCache: SyncRecordCache
    private let scratchDirectory: URL

    init() {
        let unique = UUID().uuidString
        defaults = UserDefaults(suiteName: "tablepro-favorite-pull-\(unique)") ?? .standard
        metadata = SyncMetadataStorage(userDefaults: defaults, prefix: "tests.\(unique)")
        tracker = SyncChangeTracker(metadataStorage: metadata)
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("favorite-pull-\(unique)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        recordCache = SyncRecordCache(
            directory: scratchDirectory.appendingPathComponent("SyncRecordCache", isDirectory: true),
            defaults: nil
        )
    }

    @Test("A favorite the store could not write holds back the change token and the record cache")
    func refusedFavoriteHoldsBackTheToken() async throws {
        let blocker = scratchDirectory.appendingPathComponent("not-a-directory")
        #expect(FileManager.default.createFile(atPath: blocker.path, contents: Data()))
        let manager = makeManager(databaseURL: blocker.appendingPathComponent("sql_favorites.db"))
        let favorite = SQLFavorite(name: "Revenue", query: "SELECT 1", keyword: "rev", connectionId: connectionId)
        let record = SyncRecordMapper.toCKRecord(sqlFavorite: favorite, in: Self.zoneID)
        let token = try Self.makeChangeToken()

        let acknowledged = await makeCoordinator(favorites: manager).applyPullResult(
            PullResult(changedRecords: [record], deletedRecordIDs: [], newToken: token)
        )

        #expect(!acknowledged)
        #expect(metadata.loadToken() == nil)
        #expect(recordCache.record(for: record.recordID) == nil)
    }

    @Test("A pull whose favorites were stored commits the change token and the record cache")
    func storedFavoriteCommitsTheToken() async throws {
        let manager = makeManager()
        let favorite = SQLFavorite(name: "Revenue", query: "SELECT 1", keyword: "rev", connectionId: connectionId)
        let record = SyncRecordMapper.toCKRecord(sqlFavorite: favorite, in: Self.zoneID)
        let token = try Self.makeChangeToken()

        let acknowledged = await makeCoordinator(favorites: manager).applyPullResult(
            PullResult(changedRecords: [record], deletedRecordIDs: [], newToken: token)
        )

        #expect(acknowledged)
        #expect(await manager.fetchFavorite(id: favorite.id)?.keyword == "rev")
        #expect(metadata.loadToken() != nil)
        #expect(recordCache.record(for: record.recordID) != nil)
    }

    @Test("A query deleted and a new one taking its keyword both land in one pull")
    func deleteThenCreateWithTheSameKeyword() async throws {
        let manager = makeManager()
        let deleted = SQLFavorite(name: "Revenue", query: "SELECT 1", keyword: "rev", connectionId: connectionId)
        #expect(await manager.addFavorite(deleted))
        metadata.clearDirty(type: .favorite)
        let replacement = SQLFavorite(
            name: "Revenue by region",
            query: "SELECT region, SUM(total) FROM orders GROUP BY region",
            keyword: "rev",
            connectionId: connectionId
        )
        let record = SyncRecordMapper.toCKRecord(sqlFavorite: replacement, in: Self.zoneID)
        let deletion = SyncRecordMapper.recordID(type: .favorite, id: deleted.id.uuidString, in: Self.zoneID)
        let token = try Self.makeChangeToken()

        await makeCoordinator(favorites: manager).applyPullResult(
            PullResult(changedRecords: [record], deletedRecordIDs: [deletion], newToken: token)
        )

        #expect(await manager.fetchFavorite(id: deleted.id) == nil)
        #expect(await manager.fetchFavorite(id: replacement.id)?.keyword == "rev")
        #expect(metadata.dirtyIds(for: .favorite).isEmpty)
        #expect(metadata.tombstones(for: .favorite).isEmpty)
        #expect(metadata.loadToken() != nil)
    }

    @Test("Two Macs claiming one keyword leave it with the older query and push the release")
    func keywordClaimedOnTwoMacs() async throws {
        let manager = makeManager()
        let local = SQLFavorite(
            name: "Revenue here",
            query: "SELECT 1",
            keyword: "rev",
            connectionId: connectionId,
            createdAt: Date(timeIntervalSince1970: 2_000)
        )
        #expect(await manager.addFavorite(local))
        metadata.clearDirty(type: .favorite)
        let remote = SQLFavorite(
            name: "Revenue there",
            query: "SELECT 2",
            keyword: "rev",
            connectionId: connectionId,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let record = SyncRecordMapper.toCKRecord(sqlFavorite: remote, in: Self.zoneID)
        let token = try Self.makeChangeToken()

        await makeCoordinator(favorites: manager).applyPullResult(
            PullResult(changedRecords: [record], deletedRecordIDs: [], newToken: token)
        )

        #expect(await manager.fetchFavorite(id: remote.id)?.keyword == "rev")
        #expect(await manager.fetchFavorite(id: local.id)?.keyword == nil)
        #expect(metadata.dirtyIds(for: .favorite) == Set([local.id.uuidString]))
        #expect(metadata.loadToken() != nil)
    }

    private func makeManager(databaseURL: URL? = nil) -> SQLFavoriteManager {
        let url = databaseURL ?? scratchDirectory.appendingPathComponent("sql_favorites_\(UUID().uuidString).db")
        return SQLFavoriteManager(
            storage: SQLFavoriteStorage(databaseURL: url, removeDatabaseOnDeinit: true),
            syncTracker: tracker
        )
    }

    private func makeCoordinator(favorites: SQLFavoriteManager) -> SyncCoordinator {
        let live = AppServices.live
        let services = AppServices(
            appEvents: live.appEvents,
            appSettings: live.appSettings,
            appSettingsStorage: AppSettingsStorage(userDefaults: defaults),
            connectionStorage: ConnectionStorage(
                fileURL: scratchDirectory.appendingPathComponent("connections.json"),
                userDefaults: defaults,
                syncTracker: tracker
            ),
            databaseManager: live.databaseManager,
            pluginManager: live.pluginManager,
            schemaService: live.schemaService,
            schemaRefreshService: live.schemaRefreshService,
            schemaProviderRegistry: live.schemaProviderRegistry,
            catalogChangeService: live.catalogChangeService,
            sqlFavoriteManager: favorites,
            favoriteTablesStorage: live.favoriteTablesStorage,
            favoriteDatabasesStorage: live.favoriteDatabasesStorage,
            aiChatStorage: live.aiChatStorage,
            aiKeyStorage: live.aiKeyStorage,
            aiAccessApprovals: live.aiAccessApprovals,
            groupStorage: live.groupStorage,
            tagStorage: live.tagStorage,
            sshProfileStorage: live.sshProfileStorage,
            credentialProfileStorage: live.credentialProfileStorage,
            licenseManager: live.licenseManager,
            syncMetadataStorage: metadata,
            favoritesExpansionState: live.favoritesExpansionState,
            linkedFolderWatcher: live.linkedFolderWatcher,
            queryHistoryManager: live.queryHistoryManager,
            dateFormattingService: live.dateFormattingService,
            copilotService: live.copilotService,
            mcpServerManager: live.mcpServerManager,
            syncTracker: tracker,
            themeEngine: live.themeEngine,
            welcomeRouter: live.welcomeRouter
        )
        return SyncCoordinator(services: services, recordCache: recordCache)
    }

    private static func makeChangeToken() throws -> CKServerChangeToken {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName("CKServerChangeToken", for: ChangeTokenArchive.self)
        archiver.encode(ChangeTokenArchive(), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        let token = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: CKServerChangeToken.self,
            from: archiver.encodedData
        )
        return try #require(token)
    }
}

@objc(SyncCoordinatorSQLFavoritePullTestsChangeTokenArchive)
private final class ChangeTokenArchive: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    override init() {
        super.init()
    }

    required init?(coder: NSCoder) {
        super.init()
    }

    func encode(with coder: NSCoder) {}
}
