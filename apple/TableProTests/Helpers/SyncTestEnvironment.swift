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
    private let storeSuite: EphemeralDefaults
    private let syncSuite: EphemeralDefaults
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
        storeSuite = try EphemeralDefaults("SyncTestEnvironment.\(label)")
        syncSuite = try EphemeralDefaults("SyncTestEnvironment.\(label).sync")
        defaults = storeSuite.defaults
        metadata = SyncMetadataStorage(userDefaults: syncSuite.defaults)
        // The account the scripted transport reports, recorded as already adopted so a run does not
        // start the server side over as it would for a new account.
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

    /// Licensed for sync by default, so no test depends on the license of the Mac running it.
    func makeCoordinator(
        transport: ScriptedSyncTransport,
        favorites: SQLFavoriteManager? = nil,
        makeNetworkMonitor: @escaping () -> SyncNetworkMonitor? = { nil },
        licenseGate: @escaping @MainActor () -> DisableReason? = { nil }
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
            welcomeRouter: live.welcomeRouter
        )
        return SyncCoordinator(
            services: services,
            recordCache: recordCache,
            transport: transport,
            makeNetworkMonitor: makeNetworkMonitor,
            columnLayouts: self.columnLayouts,
            licenseGate: licenseGate
        )
    }
}

actor ScriptedSyncTransport: SyncTransport {
    static let accountId = "tests"

    private let zoneID: CKRecordZone.ID
    private var duringZoneRead: @MainActor @Sendable () async -> Void = {}

    var currentZoneID: CKRecordZone.ID {
        get async {
            await duringZoneRead()
            return zoneID
        }
    }

    // Runs at every read of the zone, the way an edit lands while the coordinator waits on the transport.
    func whileZoneIsRead(_ action: @escaping @MainActor @Sendable () async -> Void) {
        duringZoneRead = action
    }
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
    private var newerServerCopies: [CKRecord.ID: CKRecord?] = [:]
    private var fetchableCopies: [CKRecord.ID: CKRecord] = [:]
    private var missingFromServer: Set<CKRecord.ID> = []

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

    // The next save of the record is refused as CloudKit refuses one built on an older copy, carrying
    // `server` as the copy it holds; nil stands for a refusal that names no copy.
    func holdNewerCopy(_ server: CKRecord?, of recordID: CKRecord.ID) {
        newerServerCopies[recordID] = .some(server)
    }

    // What a fetch by id returns, for a refusal that came without the server's copy.
    func serveOnFetch(_ server: CKRecord) {
        fetchableCopies[server.recordID] = server
    }

    // The next save of a record built on a cached copy fails as one deleted elsewhere does.
    func deleteElsewhere(_ recordID: CKRecord.ID) {
        missingFromServer.insert(recordID)
    }

    func fetch(recordIDs: [CKRecord.ID]) async throws -> [CKRecord.ID: CKRecord] {
        fetchableCopies.filter { recordIDs.contains($0.key) }
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
        self.zoneID = zoneID
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
            if missingFromServer.remove(record.recordID) != nil {
                outcome.recordFailure(
                    SyncItemFailure(code: .unknownItem, serverRecord: nil, clientRecord: record, message: "Record not found"),
                    for: record.recordID
                )
                continue
            }
            if let server = newerServerCopies.removeValue(forKey: record.recordID) {
                outcome.recordFailure(
                    SyncItemFailure(code: .serverRecordChanged, serverRecord: server, clientRecord: record, message: "Server record changed"),
                    for: record.recordID
                )
                continue
            }
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
