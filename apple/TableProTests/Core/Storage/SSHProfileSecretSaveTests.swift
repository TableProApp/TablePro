//
//  SSHProfileSecretSaveTests.swift
//  TableProTests
//

import Foundation
import TableProSSHConfig
import TableProSyncTransport
import Testing

@testable import TablePro

// The SSH profile sheet saves through `SSHProfileStorage.save`: record first, then each secret as its draft says.
@MainActor
struct SSHProfileSecretSaveTests {
    private let pool = EphemeralDefaultsPool()
    private let keychain = ScopeRecordingKeychain()
    private let metadata: SyncMetadataStorage
    private let connections: ConnectionStorage
    private let storage: SSHProfileStorage

    init() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("connections.json")
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        metadata = SyncMetadataStorage(userDefaults: try pool.make().defaults)
        let tracker = SyncChangeTracker(metadataStorage: metadata)
        let connectionStorage = ConnectionStorage(
            fileURL: fileURL,
            userDefaults: try pool.make().defaults,
            syncTracker: tracker,
            keychain: keychain
        )
        connections = connectionStorage
        storage = SSHProfileStorage(
            userDefaults: try pool.make().defaults,
            keychain: keychain,
            syncTracker: tracker,
            connectionStorage: connectionStorage
        )
    }

    private static func passwordKey(_ id: UUID) -> String { "com.TablePro.sshprofile.password.\(id.uuidString)" }
    private static func passphraseKey(_ id: UUID) -> String { "com.TablePro.sshprofile.keypassphrase.\(id.uuidString)" }
    private static func totpKey(_ id: UUID) -> String { "com.TablePro.sshprofile.totpsecret.\(id.uuidString)" }

    private func makeProfile(authMethod: SSHAuthMethod = .password) -> SSHProfile {
        SSHProfile(name: "Bastion", host: "bastion.example.com", port: 22, username: "deploy", authMethod: authMethod)
    }

    private func drafts(for id: UUID) -> [SSHProfileStorage.SecretKind: StoredSecretDraft] {
        var drafts: [SSHProfileStorage.SecretKind: StoredSecretDraft] = [:]
        for kind in SSHProfileStorage.SecretKind.allCases {
            drafts[kind] = StoredSecretDraft(stored: storage.storedSecret(kind, for: id))
        }
        return drafts
    }

    @Test("A locked Keychain reads as unreadable, a missing item as absent")
    func storedSecretTellsLockedFromMissing() {
        let profile = makeProfile()
        #expect(storage.storedSecret(.password, for: profile.id) == .absent)

        keychain.seedSynced("hunter2", forKey: Self.passwordKey(profile.id))
        #expect(storage.storedSecret(.password, for: profile.id) == .value("hunter2"))

        keychain.makeUnreadable(Self.passwordKey(profile.id))
        #expect(storage.storedSecret(.password, for: profile.id) == .unreadable)
    }

    @Test("Renaming a profile while the Keychain is locked keeps every secret")
    func lockedKeychainRenameKeepsSecrets() {
        var profile = makeProfile(authMethod: .privateKey)
        #expect(storage.addProfile(profile))
        keychain.seedSynced("hunter2", forKey: Self.passwordKey(profile.id))
        keychain.seedSynced("phrase", forKey: Self.passphraseKey(profile.id))
        keychain.seedSynced("BASE32", forKey: Self.totpKey(profile.id))
        for key in [Self.passwordKey(profile.id), Self.passphraseKey(profile.id), Self.totpKey(profile.id)] {
            keychain.makeUnreadable(key)
        }

        let loaded = drafts(for: profile.id)
        profile.name = "Bastion EU"
        let outcome = storage.save(profile, isNew: false, secrets: [
            .password: loaded[.password]?.change(inUse: false) ?? .keep,
            .keyPassphrase: loaded[.keyPassphrase]?.change(inUse: true) ?? .keep,
            .totpSecret: loaded[.totpSecret]?.change(inUse: false) ?? .keep,
        ])

        #expect(outcome == .saved)
        #expect(storage.profile(for: profile.id)?.name == "Bastion EU")
        #expect(keychain.syncedValue(forKey: Self.passwordKey(profile.id)) == "hunter2")
        #expect(keychain.syncedValue(forKey: Self.passphraseKey(profile.id)) == "phrase")
        #expect(keychain.syncedValue(forKey: Self.totpKey(profile.id)) == "BASE32")
    }

    @Test("Remove deletes a secret the Keychain could not read")
    func removeDeletesAnUnreadableSecret() {
        let profile = makeProfile()
        #expect(storage.addProfile(profile))
        keychain.seedSynced("hunter2", forKey: Self.passwordKey(profile.id))
        keychain.makeUnreadable(Self.passwordKey(profile.id))

        var password = StoredSecretDraft(stored: storage.storedSecret(.password, for: profile.id))
        password.removesUnreadable = true

        #expect(storage.save(profile, isNew: false, secrets: [.password: password.change(inUse: true)]) == .saved)
        #expect(keychain.syncedValue(forKey: Self.passwordKey(profile.id)) == nil)
    }

    @Test("A refused Keychain write is reported after the record is saved")
    func refusedWriteIsReported() {
        let profile = makeProfile()
        keychain.failWrites(to: Self.passwordKey(profile.id))

        let outcome = storage.save(profile, isNew: true, secrets: [
            .password: .write("hunter2"),
            .totpSecret: .write("BASE32"),
        ])

        #expect(outcome == .secretsNotSaved([.password]))
        #expect(storage.profile(for: profile.id) != nil)
        #expect(keychain.syncedValue(forKey: Self.totpKey(profile.id)) == "BASE32")
    }

    @Test("Nothing reaches the Keychain when the record could not be saved")
    func noSecretsWithoutARecord() throws {
        let defaults = try pool.make().defaults
        defaults.set(Data("not json".utf8), forKey: "com.TablePro.sshProfiles")
        let corrupted = SSHProfileStorage(
            userDefaults: defaults,
            keychain: keychain,
            syncTracker: SyncChangeTracker(metadataStorage: metadata),
            connectionStorage: connections
        )
        _ = corrupted.loadProfiles()
        let profile = makeProfile()

        #expect(corrupted.save(profile, isNew: true, secrets: [.password: .write("hunter2")]) == .recordNotSaved)
        #expect(keychain.syncedValue(forKey: Self.passwordKey(profile.id)) == nil)
    }
}
