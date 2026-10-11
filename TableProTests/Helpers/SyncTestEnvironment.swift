import CloudKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
final class SyncTestEnvironment {
    static let zoneID = CKRecordZone.ID(
        zoneName: CloudKitSyncEngine.zoneName,
        ownerName: CKCurrentUserDefaultName
    )

    let keychain = InMemoryKeychain()
    let directory: URL
    let defaults: UserDefaults
    let metadata: SyncMetadataStorage
    let tracker: SyncChangeTracker
    let recordCache: SyncRecordCache
    let connections: ConnectionStorage
    let groups: GroupStorage
    let tags: TagStorage
    let favoriteTables: FavoriteTablesStorage
    let favoriteDatabases: FavoriteDatabasesStorage
    let columnLayouts: FileColumnLayoutPersister
    let tableFolders: TableFolderStorage
    let favorites: SQLFavoriteManager

    init(label: String) throws {
        let unique = UUID().uuidString
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("\(label)-\(unique)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.\(label).\(unique)"))
        metadata = SyncMetadataStorage(
            userDefaults: try #require(UserDefaults(suiteName: "com.TablePro.tests.\(label).sync.\(unique)"))
        )
        /// The account the scripted transport reports, recorded as already adopted so a run does not
        /// start the server side over as it would for a new account.
        metadata.lastAccountId = ScriptedSyncTransport.accountId
        tracker = SyncChangeTracker(metadataStorage: metadata)
        recordCache = SyncRecordCache(
            directory: directory.appendingPathComponent("SyncRecordCache", isDirectory: true),
            defaults: nil
        )
        let connectionStore = ConnectionStorage(
            fileURL: directory.appendingPathComponent("connections.json"),
            userDefaults: defaults,
            syncTracker: tracker,
            keychain: keychain,
            integrity: ConnectionStoreIntegrity(keySource: StoredIntegrityKeySource(store: keychain))
        )
        connections = connectionStore
        groups = GroupStorage(
            userDefaults: defaults,
            syncTracker: tracker,
            connectionStorage: connectionStore,
            appEvents: AppEvents()
        )
        tags = TagStorage(userDefaults: defaults, syncTracker: tracker, appEvents: AppEvents())
        favoriteTables = FavoriteTablesStorage(userDefaults: defaults, syncTracker: tracker)
        favoriteDatabases = FavoriteDatabasesStorage(defaults: defaults, syncTracker: tracker)
        columnLayouts = FileColumnLayoutPersister(
            storageDirectory: directory.appendingPathComponent("ColumnLayout", isDirectory: true),
            defaults: defaults,
            syncTracker: tracker
        )
        tableFolders = TableFolderStorage(defaults: defaults, syncTracker: tracker, notificationCenter: NotificationCenter())
        favorites = SQLFavoriteManager(
            storage: SQLFavoriteStorage(
                databaseURL: directory.appendingPathComponent("sql_favorites.db"),
                removeDatabaseOnDeinit: true
            ),
            syncTracker: tracker
        )
    }

    func makeCoordinator(
        transport: ScriptedSyncTransport,
        favorites: SQLFavoriteManager? = nil
    ) -> SyncCoordinator {
        let live = AppServices.live
        let services = AppServices(
            appEvents: AppEvents(),
            appSettings: live.appSettings,
            appSettingsStorage: AppSettingsStorage(userDefaults: defaults),
            connectionStorage: connections,
            databaseManager: live.databaseManager,
            pluginManager: live.pluginManager,
            schemaService: live.schemaService,
            schemaRefreshService: live.schemaRefreshService,
            schemaProviderRegistry: live.schemaProviderRegistry,
            catalogChangeService: live.catalogChangeService,
            sqlFavoriteManager: favorites ?? self.favorites,
            favoriteTablesStorage: favoriteTables,
            favoriteDatabasesStorage: favoriteDatabases,
            tableFolderStorage: tableFolders,
            aiChatStorage: live.aiChatStorage,
            aiKeyStorage: live.aiKeyStorage,
            aiAccessApprovals: live.aiAccessApprovals,
            groupStorage: groups,
            tagStorage: tags,
            sshProfileStorage: SSHProfileStorage(
                userDefaults: defaults,
                keychain: keychain,
                syncTracker: tracker,
                connectionStorage: self.connections
            ),
            credentialProfileStorage: CredentialProfileStorage(
                fileURL: directory.appendingPathComponent("credentialProfiles.json"),
                keychain: keychain,
                syncTracker: tracker,
                connectionStorage: self.connections,
                integrity: ConnectionStoreIntegrity(keySource: StoredIntegrityKeySource(store: keychain))
            ),
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
        return SyncCoordinator(
            services: services,
            recordCache: recordCache,
            transport: transport,
            networkMonitor: nil,
            columnLayouts: self.columnLayouts
        )
    }
}

actor ScriptedSyncTransport: SyncTransport {
    static let accountId = "tests"

    let currentZoneID: CKRecordZone.ID
    private let rejectedRecordIDs: Set<CKRecord.ID>
    private let missingRecordIDs: Set<CKRecord.ID>
    private let interruption: (any Error)?
    private let duringPush: @MainActor @Sendable () async -> Void
    private let pulled: @Sendable (_ records: [CKRecord], _ deletions: [CKRecord.ID]) -> PullResult
    private(set) var pushedRecords: [CKRecord] = []
    private(set) var pushedDeletions: [CKRecord.ID] = []
    private(set) var pullCount = 0
    private(set) var pushCount = 0
    private(set) var zoneSaveCount = 0

    /// What the account reads as, what every pushed item fails with, and what a pull throws. Each
    /// is changeable mid-test, the way the account or the storage changes under a running app.
    private(set) var accountStatusValue: CKAccountStatus = .available
    private(set) var accountIdValue = ScriptedSyncTransport.accountId
    private(set) var everyItemFails: (code: CKError.Code, retryAfter: TimeInterval?)?
    private(set) var pullError: (any Error)?

    func setAccountStatus(_ status: CKAccountStatus) {
        accountStatusValue = status
    }

    func setAccountId(_ accountId: String) {
        accountIdValue = accountId
    }

    func failEveryItem(with code: CKError.Code?, retryAfter: TimeInterval? = nil) {
        everyItemFails = code.map { (code: $0, retryAfter: retryAfter) }
    }

    func failPulls(with error: (any Error)?) {
        pullError = error
    }

    init(
        zoneID: CKRecordZone.ID,
        rejecting rejectedRecordIDs: Set<CKRecord.ID> = [],
        missing missingRecordIDs: Set<CKRecord.ID> = [],
        interruption: (any Error)? = nil,
        duringPush: @escaping @MainActor @Sendable () async -> Void = {},
        pulled: @escaping @Sendable ([CKRecord]) -> PullResult = { _ in
            PullResult(changedRecords: [], deletedRecordIDs: [], newToken: nil)
        }
    ) {
        self.init(
            zoneID: zoneID,
            rejecting: rejectedRecordIDs,
            missing: missingRecordIDs,
            interruption: interruption,
            duringPush: duringPush,
            echoing: { records, _ in pulled(records) }
        )
    }

    init(
        zoneID: CKRecordZone.ID,
        rejecting rejectedRecordIDs: Set<CKRecord.ID> = [],
        missing missingRecordIDs: Set<CKRecord.ID> = [],
        interruption: (any Error)? = nil,
        duringPush: @escaping @MainActor @Sendable () async -> Void = {},
        echoing pulled: @escaping @Sendable (_ records: [CKRecord], _ deletions: [CKRecord.ID]) -> PullResult
    ) {
        self.currentZoneID = zoneID
        self.rejectedRecordIDs = rejectedRecordIDs
        self.missingRecordIDs = missingRecordIDs
        self.interruption = interruption
        self.duringPush = duringPush
        self.pulled = pulled
    }

    func accountStatus() async throws -> CKAccountStatus {
        accountStatusValue
    }

    func currentAccountId() async throws -> String {
        accountIdValue
    }

    func ensureZoneExists() async throws {
        zoneSaveCount += 1
    }

    func push(records: [CKRecord], deletions: [CKRecord.ID]) async throws -> PushOutcome {
        pushCount += 1
        pushedRecords.append(contentsOf: records)
        pushedDeletions.append(contentsOf: deletions)
        await duringPush()
        var outcome = PushOutcome()
        if let everyItemFails {
            for recordID in records.map(\.recordID) + deletions {
                outcome.recordFailure(
                    SyncItemFailure(
                        code: everyItemFails.code,
                        serverRecord: nil,
                        clientRecord: nil,
                        retryAfter: everyItemFails.retryAfter,
                        message: "Error saving record <CKRecordID: \(recordID.recordName)>: scripted failure"
                    ),
                    for: recordID
                )
            }
            return outcome
        }
        for record in records {
            guard rejectedRecordIDs.contains(record.recordID) else {
                outcome.recordSave(record)
                continue
            }
            outcome.recordFailure(
                SyncItemFailure(code: .serverRejectedRequest, serverRecord: nil, clientRecord: record, message: "Rejected"),
                for: record.recordID
            )
        }
        for recordID in deletions {
            guard missingRecordIDs.contains(recordID) else {
                outcome.recordDeletion(recordID)
                continue
            }
            outcome.recordFailure(
                SyncItemFailure(code: .unknownItem, serverRecord: nil, clientRecord: nil, message: "Record not found"),
                for: recordID
            )
        }
        if let interruption {
            throw SyncPushInterruption(completed: outcome, cause: interruption)
        }
        return outcome
    }

    func pull(since token: CKServerChangeToken?) async throws -> PullResult {
        pullCount += 1
        if let pullError {
            throw pullError
        }
        return pulled(pushedRecords, pushedDeletions)
    }
}
