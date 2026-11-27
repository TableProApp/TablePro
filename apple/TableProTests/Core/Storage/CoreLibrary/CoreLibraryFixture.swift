//
//  CoreLibraryFixture.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProSyncTransport

// One Mac's library folder. Each `launch()` is a new run of the app over the same files and defaults.
@MainActor
final class CoreLibraryFixture {
    let directory: URL
    let keychain = InMemoryKeychain()
    let journal = SyncJournalRecorder()
    let events = AppEvents()
    private let suites = EphemeralDefaultsPool()
    let defaults: UserDefaults

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreLibrary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = try suites.make().defaults
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var legacyURL: URL { directory.appendingPathComponent("connections.json") }
    var coreURL: URL { directory.appendingPathComponent("Core/connections.json") }

    func launch() -> ConnectionStorage {
        ConnectionStorage(
            fileURL: legacyURL,
            userDefaults: defaults,
            syncJournal: journal.journal,
            keychain: keychain,
            appEvents: self.events
        )
    }

    func groups(_ storage: ConnectionStorage) -> GroupStorage {
        GroupStorage(syncJournal: journal.journal, connectionStorage: storage, appEvents: events)
    }

    func tags(_ storage: ConnectionStorage) -> TagStorage {
        TagStorage(syncJournal: journal.journal, connectionStorage: storage, appEvents: events)
    }

    func projects(_ storage: ConnectionStorage) -> ProjectStorage {
        ProjectStorage(
            syncJournal: journal.journal,
            connectionStorage: storage,
            groupStorage: self.groups(storage),
            appEvents: events
        )
    }

    func sshProfiles(_ storage: ConnectionStorage) -> SSHProfileStorage {
        SSHProfileStorage(keychain: keychain, syncJournal: journal.journal, connectionStorage: storage)
    }

    func credentialProfiles(_ storage: ConnectionStorage) -> CredentialProfileStorage {
        CredentialProfileStorage(keychain: keychain, syncJournal: journal.journal, connectionStorage: storage)
    }

    var credentialProfilesURL: URL { directory.appendingPathComponent("credentialProfiles.json") }

    func legacySSHProfiles() throws -> [SSHProfile] {
        try JSONDecoder().decode([SSHProfile].self, from: defaults.data(forKey: "com.TablePro.sshProfiles") ?? Data())
    }

    func legacyCredentialProfiles() throws -> [CredentialProfile] {
        try JSONDecoder().decode([CredentialProfile].self, from: Data(contentsOf: credentialProfilesURL))
    }

    func legacyProjects() throws -> [ConnectionProject] {
        try JSONDecoder().decode([ConnectionProject].self, from: defaults.data(forKey: "com.TablePro.projects") ?? Data())
    }

    func preferences(_ storage: ConnectionStorage) -> ConnectionListPreferences {
        ConnectionListPreferences(defaults: defaults, connectionStorage: storage, appEvents: events)
    }

    // What the previous stable reads: its own files, decoded the way it decodes them.
    func legacyConnections() throws -> [DatabaseConnection] {
        try JSONDecoder().decode([StoredConnection].self, from: Data(contentsOf: legacyURL)).map { $0.toConnection() }
    }

    func legacyGroups() throws -> [ConnectionGroup] {
        try JSONDecoder().decode([ConnectionGroup].self, from: defaults.data(forKey: "com.TablePro.groups") ?? Data())
    }

    func legacyTags() throws -> [ConnectionTag] {
        try JSONDecoder().decode([ConnectionTag].self, from: defaults.data(forKey: "com.TablePro.tags") ?? Data())
    }

    var legacyFavoritesOrder: [UUID] {
        (defaults.stringArray(forKey: PreferenceKeys.connectionListFavoritesOrder.name) ?? []).compactMap(UUID.init(uuidString:))
    }

    // A write by a build before the core, in its own formats.
    func writeAsPreviousStable(
        connections: [DatabaseConnection],
        groups: [ConnectionGroup]? = nil,
        tags: [ConnectionTag]? = nil,
        favoritesOrder: [UUID]? = nil
    ) throws {
        try JSONEncoder().encode(connections.map { StoredConnection(from: $0) }).write(to: legacyURL, options: .atomic)
        if let groups {
            defaults.set(try JSONEncoder().encode(groups), forKey: "com.TablePro.groups")
        }
        if let tags {
            defaults.set(try JSONEncoder().encode(tags), forKey: "com.TablePro.tags")
        }
        if let favoritesOrder {
            defaults.set(favoritesOrder.map(\.uuidString), forKey: PreferenceKeys.connectionListFavoritesOrder.name)
        }
    }

    // The tag a TablePro build writes beside the core's file for these bytes.
    func stampCore(_ bytes: Data) -> Bool {
        ConnectionStoreIntegrity.shared.stamp(
            CoreLibraryStore.tag(forDigest: LegacyLibraryMirror.digest(of: bytes)),
            fileURL: coreURL
        )
    }

    // The core's store alone: the previous stable's files are gone, so a launch can only read the core.
    func launchFromCoreOnly() throws -> ConnectionStorage {
        try FileManager.default.removeItem(at: legacyURL)
        return launch()
    }
}
