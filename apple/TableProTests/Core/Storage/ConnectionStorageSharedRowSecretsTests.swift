//
//  ConnectionStorageSharedRowSecretsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

// A team row is never saved, so what the team's envelopes opened to stands in for its Keychain items, in memory only.
@MainActor
struct ConnectionStorageSharedRowSecretsTests {
    private let keychain = RecordingKeychain()
    private let storage: ConnectionStorage
    private let suite: EphemeralDefaults

    init() throws {
        suite = try EphemeralDefaults()
        storage = ConnectionStorage(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tablepro-shared-row-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("connections.json"),
            userDefaults: suite.defaults,
            keychain: keychain
        )
    }

    @Test("A connect reads a team row's secrets, which never reach the Keychain")
    func connectReadsTheRowsSecrets() async {
        let row = UUID()

        storage.setSharedRowSecrets([.password: "s3cret", .sshPassword: "tunnel"], for: row)
        let read = await DeferredSecretRead.run([storage.passwordRead(for: row), storage.sshPasswordRead(for: row)])

        #expect(read.values.sorted() == ["s3cret", "tunnel"])
        #expect(storage.loadPassword(for: row) == "s3cret")
        #expect(storage.loadKeyPassphrase(for: row) == nil)
        #expect(keychain.writeCount == 0)
        #expect(keychain.keys.isEmpty)
    }

    @Test("An item the Keychain holds wins, as a form's Test stages one")
    func keychainItemWins() async {
        let row = UUID()
        storage.setSharedRowSecrets([.password: "team"], for: row)
        storage.savePassword("typed", for: row)

        let read = await DeferredSecretRead.run([storage.passwordRead(for: row)])

        #expect(read.values.first == "typed")
    }

    @Test("Setting a row's secrets again drops the ones the team no longer holds, and a sign-out forgets them all")
    func replacedAndForgotten() async {
        let row = UUID()
        let other = UUID()
        storage.setSharedRowSecrets([.password: "old", .sshPassword: "tunnel"], for: row)
        storage.setSharedRowSecrets([.password: "other"], for: other)

        storage.setSharedRowSecrets([.password: "new"], for: row)
        #expect(storage.loadPassword(for: row) == "new")
        #expect(storage.loadSSHPassword(for: row) == nil)
        #expect(storage.loadPassword(for: other) == "other")

        storage.removeSharedRowSecrets()
        #expect(storage.loadPassword(for: row) == nil)
        #expect(storage.loadPassword(for: other) == nil)
    }
}
