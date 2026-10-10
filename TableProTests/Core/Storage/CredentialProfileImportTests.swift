//
//  CredentialProfileImportTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProImport
import TableProSyncTransport
import Testing

@MainActor
struct CredentialProfileImportTests {
    private let directory: URL
    private let keychain = InMemoryKeychain()
    private let metadata: SyncMetadataStorage
    private let integrity: ConnectionStoreIntegrity
    private let connections: ConnectionStorage
    private let storage: CredentialProfileStorage

    init() throws {
        let unique = UUID().uuidString
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("credential-import-\(unique)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        metadata = SyncMetadataStorage(
            userDefaults: try #require(UserDefaults(suiteName: "com.TablePro.tests.CredentialImport.sync.\(unique)"))
        )
        integrity = ConnectionStoreIntegrity(keySource: StoredIntegrityKeySource(store: keychain))
        let tracker = SyncChangeTracker(metadataStorage: metadata)
        let connectionStorage = ConnectionStorage(
            fileURL: directory.appendingPathComponent("connections.json"),
            userDefaults: try #require(UserDefaults(suiteName: "com.TablePro.tests.CredentialImport.\(unique)")),
            syncTracker: tracker,
            keychain: keychain,
            integrity: integrity
        )
        connections = connectionStorage
        storage = CredentialProfileStorage(
            fileURL: directory.appendingPathComponent("credentialProfiles.json"),
            keychain: keychain,
            syncTracker: tracker,
            connectionStorage: connectionStorage,
            integrity: integrity
        )
    }

    private func planned(
        _ ref: BundleRef,
        name: String,
        username: String = "reader",
        passwordMode: BundlePasswordMode = .prompt,
        secureFieldIds: [String] = []
    ) -> PlannedCredentialProfile {
        PlannedCredentialProfile(
            ref: ref,
            name: name,
            username: username,
            passwordMode: passwordMode,
            secureFieldIds: secureFieldIds
        )
    }

    @Test("A profile name already on this Mac is never returned and never duplicated")
    func existingNameIsNeverReturned() throws {
        #expect(storage.addProfile(CredentialProfile(name: "Prod Reader", username: "local_user")))

        let created = try #require(storage.addImportedProfiles([
            planned("p1", name: "prod reader", username: "file_user"),
            planned("p2", name: "Analytics")
        ]))

        #expect(Set(created.keys) == [BundleRef("p2")])
        #expect(storage.loadProfiles().count == 2)
        #expect(storage.loadProfiles().first { $0.name == "Prod Reader" }?.username == "local_user")
    }

    @Test("A created profile asks for its password unless it reads pgpass")
    func createdProfileAsksForItsPassword() throws {
        let created = try #require(storage.addImportedProfiles([
            planned("stored", name: "Stored", passwordMode: .stored, secureFieldIds: ["awsSecretAccessKey"]),
            planned("pgpass", name: "Pgpass", passwordMode: .pgpass)
        ]))

        let storedId = try #require(created["stored"])
        let stored = try #require(storage.profile(for: storedId))
        #expect(stored.passwordMode == .prompt)
        #expect(stored.secureFieldIds == ["awsSecretAccessKey"])
        let pgpassId = try #require(created["pgpass"])
        #expect(storage.profile(for: pgpassId)?.passwordMode == .pgpass)
    }

    @Test("Two rows with one name create one profile")
    func repeatedNameCreatesOneProfile() throws {
        let created = try #require(storage.addImportedProfiles([
            planned("p1", name: "Shared"),
            planned("p2", name: " shared ")
        ]))

        #expect(Set(created.keys) == [BundleRef("p1")])
        #expect(storage.loadProfiles().count == 1)
    }

    @Test("Created profiles are saved in one batch and marked dirty")
    func createdProfilesAreDirty() throws {
        let created = try #require(storage.addImportedProfiles([
            planned("p1", name: "One"),
            planned("p2", name: "Two")
        ]))

        #expect(metadata.dirtyIds(for: .credentialProfile) == Set(created.values.map(\.uuidString)))
        #expect(storage.loadProfiles().map(\.sortOrder) == [0, 1])
    }

    @Test("An unreadable profile store returns nil and keeps its bytes")
    func unreadableStoreReturnsNil() throws {
        let fileURL = directory.appendingPathComponent("unreadable-profiles.json")
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: fileURL)
        let unreadable = CredentialProfileStorage(
            fileURL: fileURL,
            keychain: keychain,
            syncTracker: SyncChangeTracker(metadataStorage: metadata),
            connectionStorage: connections,
            integrity: integrity
        )

        #expect(unreadable.addImportedProfiles([planned("p1", name: "Reader")]) == nil)
        #expect(unreadable.addImportedProfiles([])?.isEmpty == true)
        #expect(try Data(contentsOf: fileURL) == corrupt)
    }
}
