//
//  ConnectionStorageImportTests.swift
//  TableProTests
//

import Combine
import Foundation
import os
@testable import TablePro
import TableProImport
import TableProSyncTransport
import Testing

@MainActor
struct ConnectionStorageImportTests {
    private let unique = UUID().uuidString
    private let directory: URL
    private let keychain = InMemoryKeychain()
    private let syncDefaults: DirtyWriteCountingDefaults
    private let metadata: SyncMetadataStorage
    private let events: AppEvents

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("connection-import-\(unique)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        syncDefaults = try #require(
            DirtyWriteCountingDefaults(suiteName: "com.TablePro.tests.ConnectionImport.sync.\(unique)")
        )
        metadata = SyncMetadataStorage(userDefaults: syncDefaults)
        events = AppEvents()
    }

    private var fileURL: URL {
        directory.appendingPathComponent("connections.json")
    }

    private func makeStorage() throws -> ConnectionStorage {
        ConnectionStorage(
            fileURL: fileURL,
            userDefaults: try #require(UserDefaults(suiteName: "com.TablePro.tests.ConnectionImport.\(unique)")),
            syncTracker: SyncChangeTracker(metadataStorage: metadata),
            keychain: keychain,
            appEvents: events,
            integrity: ConnectionStoreIntegrity(keySource: StoredIntegrityKeySource(store: keychain))
        )
    }

    private func services(with connectionStorage: ConnectionStorage) -> AppServices {
        let live = AppServices.live
        return AppServices(
            appEvents: events,
            appSettings: live.appSettings,
            appSettingsStorage: live.appSettingsStorage,
            connectionStorage: connectionStorage,
            databaseManager: live.databaseManager,
            pluginManager: live.pluginManager,
            schemaService: live.schemaService,
            schemaRefreshService: live.schemaRefreshService,
            schemaProviderRegistry: live.schemaProviderRegistry,
            catalogChangeService: live.catalogChangeService,
            sqlFavoriteManager: live.sqlFavoriteManager,
            favoriteTablesStorage: live.favoriteTablesStorage,
            favoriteDatabasesStorage: live.favoriteDatabasesStorage,
            tableFolderStorage: live.tableFolderStorage,
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
            syncTracker: SyncChangeTracker(metadataStorage: metadata),
            themeEngine: live.themeEngine,
            welcomeRouter: live.welcomeRouter
        )
    }

    @Test("An unreadable library refuses every write and keeps its bytes")
    func unreadableLibraryRefusesWrites() throws {
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: fileURL)

        let neverLoaded = try makeStorage()
        #expect(!neverLoaded.saveConnections([DatabaseConnection(name: "Cold save")]))

        let storage = try makeStorage()
        #expect(storage.isLibraryUnreadable)
        #expect(!storage.addConnection(DatabaseConnection(name: "New")))
        #expect(!storage.saveConnections([DatabaseConnection(name: "Replacement")]))
        #expect(storage.applyImport(adding: [DatabaseConnection(name: "Imported")], replacing: []) == nil)

        #expect(try Data(contentsOf: fileURL) == corrupt)
        #expect(syncDefaults.dirtyWrites(for: .connection) == 0)
    }

    @Test("The connection form blames the unreadable library, not the disk, and writes nothing")
    func connectionFormExplainsUnreadableLibrary() throws {
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: fileURL)
        let coordinator = ConnectionFormCoordinator(connectionId: nil, services: try services(with: makeStorage()))

        coordinator.save()

        #expect(coordinator.saveError == String(
            localized: "TablePro could not read your saved connections, so it did not save over them."
        ))
        #expect(try Data(contentsOf: fileURL) == corrupt)
    }

    @Test("A save that cannot reach the disk reports nothing imported")
    func unwritableFolderReturnsNil() throws {
        let storage = try makeStorage()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }
        var announcements = 0
        let subscription = events.connectionUpdated.sink { _ in announcements += 1 }
        defer { subscription.cancel() }

        let write = storage.applyImport(adding: [DatabaseConnection(name: "Imported")], replacing: [])

        #expect(write == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(syncDefaults.dirtyWrites(for: .connection) == 0)
        #expect(announcements == 0)
    }

    @Test("A replace whose connection is gone is neither written nor returned")
    func vanishedReplaceIsNotReturned() throws {
        let storage = try makeStorage()
        let kept = DatabaseConnection(name: "Kept")
        #expect(storage.addConnection(kept))
        let before = try Data(contentsOf: fileURL)

        let nothing = storage.applyImport(adding: [], replacing: [DatabaseConnection(name: "Ghost")])

        #expect(nothing == ConnectionImportWrite(added: [], replaced: []))
        #expect(try Data(contentsOf: fileURL) == before)

        var renamed = kept
        renamed.name = "Kept, renamed"
        let mixed = storage.applyImport(adding: [], replacing: [DatabaseConnection(name: "Ghost"), renamed])

        #expect(mixed == ConnectionImportWrite(added: [], replaced: [kept.id]))
        storage.invalidateCache()
        #expect(storage.loadConnections().map(\.name) == ["Kept, renamed"])
    }

    @Test("An import marks its syncing rows in one batch and announces once")
    func oneDirtyBatchAndOneAnnouncement() throws {
        let storage = try makeStorage()
        let existing = DatabaseConnection(name: "Existing")
        #expect(storage.addConnection(existing))
        metadata.clearDirty(type: .connection)
        syncDefaults.resetWrites()
        var announcements: [UUID?] = []
        let subscription = events.connectionUpdated.sink { announcements.append($0) }
        defer { subscription.cancel() }

        var replacement = existing
        replacement.name = "Existing, replaced"
        let synced = DatabaseConnection(name: "Synced")
        let localOnly = DatabaseConnection(name: "Local", localOnly: true)
        let write = storage.applyImport(adding: [synced, localOnly], replacing: [replacement])

        #expect(write == ConnectionImportWrite(added: [synced.id, localOnly.id], replaced: [existing.id]))
        #expect(metadata.dirtyIds(for: .connection) == [existing.id.uuidString, synced.id.uuidString])
        #expect(syncDefaults.dirtyWrites(for: .connection) == 1)
        #expect(announcements == [nil])
    }

    @Test("A replace keeps device-local state and its place in an unchanged group")
    func replaceKeepsDeviceLocalStateAndOrder() throws {
        let storage = try makeStorage()
        let group = UUID()
        #expect(storage.addConnection(DatabaseConnection(name: "First", groupId: group)))
        var second = DatabaseConnection(
            name: "Second",
            groupId: group,
            localOnly: true,
            passwordSource: .command(shell: "pass show db")
        )
        second.externalAccess = .blocked
        #expect(storage.addConnection(second))
        let storedOrder = try #require(storage.loadConnection(id: second.id)).sortOrder

        let incoming = DatabaseConnection(id: second.id, name: "Second, from the file", groupId: group)
        let write = storage.applyImport(adding: [], replacing: [incoming])

        #expect(write?.replaced == [second.id])
        storage.invalidateCache()
        let replaced = try #require(storage.loadConnection(id: second.id))
        #expect(replaced.name == "Second, from the file")
        #expect(replaced.localOnly)
        #expect(replaced.passwordSource == .command(shell: "pass show db"))
        #expect(replaced.externalAccess == .blocked)
        #expect(replaced.sortOrder == storedOrder)
    }

    @Test("A replace that changes group goes to the end of the new group")
    func replaceIntoAnotherGroupGoesLast() throws {
        let storage = try makeStorage()
        let source = UUID()
        let target = UUID()
        let resident = DatabaseConnection(name: "Resident", groupId: target)
        let moving = DatabaseConnection(name: "Moving", groupId: source)
        #expect(storage.addConnection(resident))
        #expect(storage.addConnection(moving))
        let residentOrder = try #require(storage.loadConnection(id: resident.id)).sortOrder

        _ = storage.applyImport(adding: [], replacing: [DatabaseConnection(id: moving.id, name: "Moving", groupId: target)])

        storage.invalidateCache()
        let moved = try #require(storage.loadConnection(id: moving.id))
        #expect(moved.groupId == target)
        #expect(moved.sortOrder > residentOrder)
    }

    @Test("A replace keeps the stored profile link unless the import linked a profile it created")
    func replaceKeepsProfileLinkUnlessImportLinkedOne() throws {
        let storage = try makeStorage()
        let existingProfile = UUID()
        let createdProfile = UUID()
        let keepsLink = DatabaseConnection(name: "Keeps link", credentialMode: .profile(id: existingProfile))
        let takesNewLink = DatabaseConnection(name: "Takes new link", credentialMode: .profile(id: existingProfile))
        #expect(storage.addConnection(keepsLink))
        #expect(storage.addConnection(takesNewLink))

        _ = storage.applyImport(adding: [], replacing: [
            DatabaseConnection(id: keepsLink.id, name: "Keeps link"),
            DatabaseConnection(id: takesNewLink.id, name: "Takes new link", credentialMode: .profile(id: createdProfile))
        ])

        storage.invalidateCache()
        #expect(storage.loadConnection(id: keepsLink.id)?.credentialMode == .profile(id: existingProfile))
        #expect(storage.loadConnection(id: takesNewLink.id)?.credentialMode == .profile(id: createdProfile))
    }

    @Test("A replace applies a tunnel command the user agreed to import, and keeps the stored one otherwise")
    func replaceAppliesAgreedTunnelCommand() throws {
        let storage = try makeStorage()
        let stored = TunnelCommandConfiguration(method: .kubectl, kubernetesResource: "service/old")
        let imported = TunnelCommandConfiguration(method: .kubectl, kubernetesResource: "service/new")
        let gainsCommand = DatabaseConnection(name: "Gains command")
        var keepsCommand = DatabaseConnection(name: "Keeps command")
        keepsCommand.tunnelCommandMode = .inline(stored)
        #expect(storage.addConnection(gainsCommand))
        #expect(storage.addConnection(keepsCommand))

        var incoming = DatabaseConnection(id: gainsCommand.id, name: "Gains command")
        incoming.tunnelCommandMode = .inline(imported)
        _ = storage.applyImport(adding: [], replacing: [
            incoming,
            DatabaseConnection(id: keepsCommand.id, name: "Keeps command")
        ])

        storage.invalidateCache()
        #expect(storage.loadConnection(id: gainsCommand.id)?.resolvedTunnelCommandConfig == imported)
        #expect(storage.loadConnection(id: keepsCommand.id)?.resolvedTunnelCommandConfig == stored)
    }

    @Test("Added connections go to the end of their group in order")
    func addsGoToTheEndOfTheirGroup() throws {
        let storage = try makeStorage()
        let group = UUID()
        let resident = DatabaseConnection(name: "Resident", groupId: group)
        #expect(storage.addConnection(resident))
        let first = DatabaseConnection(name: "First import", groupId: group)
        let second = DatabaseConnection(name: "Second import", groupId: group)

        let write = storage.applyImport(adding: [first, second, first], replacing: [])

        #expect(write?.added == [first.id, second.id])
        storage.invalidateCache()
        let orders = [resident.id, first.id, second.id].compactMap { storage.loadConnection(id: $0)?.sortOrder }
        #expect(orders.count == 3)
        #expect(orders == orders.sorted())
        #expect(Set(orders).count == 3)
    }
}

private final class DirtyWriteCountingDefaults: UserDefaults {
    private let writes = OSAllocatedUnfairLock(initialState: [String: Int]())

    func dirtyWrites(for type: SyncRecordType) -> Int {
        let suffix = ".dirty.\(type.rawValue)"
        return writes.withLock { counts in
            counts.filter { $0.key.hasSuffix(suffix) }.values.reduce(0, +)
        }
    }

    func resetWrites() {
        writes.withLock { $0 = [:] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        writes.withLock { $0[defaultName, default: 0] += 1 }
        super.set(value, forKey: defaultName)
    }
}
