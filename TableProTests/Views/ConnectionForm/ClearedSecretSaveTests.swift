//
//  ClearedSecretSaveTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// Emptying a password field and saving has to delete the stored secret. Leaving it behind means
/// the next connect still authenticates with the old password, an encrypted export still carries
/// it, and a duplicate copies it.
@Suite("Cleared secrets are deleted on save")
@MainActor
struct ClearedSecretSaveTests {
    private final class ScriptedKeychain: KeychainStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var result: KeychainStringResult

        init(_ result: KeychainStringResult) {
            self.result = result
        }

        @discardableResult
        func writeString(_ value: String, forKey key: String) -> Bool { true }

        func readStringResult(forKey key: String) -> KeychainStringResult {
            lock.lock()
            defer { lock.unlock() }
            return result
        }

        func delete(forKey key: String) {}
    }

    private func makeStorage(_ result: KeychainStringResult) -> ConnectionStorage {
        let unique = UUID().uuidString
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent(unique)
            .appendingPathComponent("connections.json")
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return ConnectionStorage(
            fileURL: fileURL,
            userDefaults: UserDefaults(suiteName: "com.TablePro.tests.ClearedSecret.\(unique)")!,
            keychain: ScriptedKeychain(result)
        )
    }

    @Test("Clearing a password that was stored asks for the stored one to be deleted")
    func clearedPasswordIsDeleted() {
        let model = AuthPaneViewModel()
        model.load(from: TestFixtures.makeConnection(), storage: makeStorage(.found("hunter2")))
        model.password = ""

        #expect(model.clearsStoredPassword)
    }

    @Test("Leaving a loaded password in place deletes nothing")
    func untouchedPasswordIsKept() {
        let model = AuthPaneViewModel()
        model.load(from: TestFixtures.makeConnection(), storage: makeStorage(.found("hunter2")))

        #expect(!model.clearsStoredPassword)
    }

    @Test("An empty field on a connection that never had a password deletes nothing")
    func neverStoredDeletesNothing() {
        let model = AuthPaneViewModel()
        model.load(from: TestFixtures.makeConnection(), storage: makeStorage(.notFound))
        model.password = ""

        #expect(!model.clearsStoredPassword)
    }

    @Test(
        "A keychain that could not be read never causes a delete",
        arguments: [
            KeychainStringResult.locked,
            .userCancelled,
            .authFailed,
            .error(-25_300),
        ]
    )
    func unreadableKeychainNeverDeletes(_ result: KeychainStringResult) {
        let model = AuthPaneViewModel()
        model.load(from: TestFixtures.makeConnection(), storage: makeStorage(result))
        model.password = ""

        #expect(!model.clearsStoredPassword)
    }

    @Test("Switching to prompt mode is handled by the prompt arm, not by the cleared arm")
    func promptModeIsNotACleared() {
        let model = AuthPaneViewModel()
        model.load(from: TestFixtures.makeConnection(), storage: makeStorage(.found("hunter2")))
        model.password = ""
        model.promptForPassword = true

        #expect(!model.clearsStoredPassword)
        #expect(model.effectivePromptForPassword)
    }

    @Test("An emptied inline SSH password and passphrase are deleted too")
    func clearedInlineSSHSecretsAreDeleted() {
        var state = SSHTunnelFormState()
        state.enabled = true
        state.loadSecrets(connectionId: UUID(), storage: makeStorage(.found("secret")))
        state.password = ""
        state.keyPassphrase = ""

        #expect(state.clearsStoredPassword)
        #expect(state.clearsStoredKeyPassphrase)
    }

    @Test("An inline SSH secret that could not be read is never deleted")
    func unreadableInlineSSHSecretsAreKept() {
        var state = SSHTunnelFormState()
        state.enabled = true
        state.loadSecrets(connectionId: UUID(), storage: makeStorage(.locked))
        state.password = ""
        state.keyPassphrase = ""

        #expect(!state.clearsStoredPassword)
        #expect(!state.clearsStoredKeyPassphrase)
    }
}
