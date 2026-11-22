import Foundation
import TableProSSHConfig
import Testing

@testable import TablePro

// A secret left behind still authenticates the next connect, rides along in an export and is copied by a duplicate.
@MainActor
struct ClearedSecretSaveTests {
    private let suite: EphemeralDefaults

    init() throws {
        suite = try EphemeralDefaults()
    }

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
            userDefaults: suite.defaults,
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

    @Test("Showing an inline SSH secret the Keychain returned asks for authentication first")
    func savedInlineSSHSecretsNeedAuthenticationToShow() {
        var state = SSHTunnelFormState()
        state.enabled = true
        state.loadSecrets(connectionId: UUID(), storage: makeStorage(.found("secret")))

        #expect(state.savedSecrets == [.password, .keyPassphrase, .totpSecret])
    }

    @Test("A connection with no inline SSH secrets has nothing to guard")
    func absentInlineSSHSecretsNeedNoAuthentication() {
        var state = SSHTunnelFormState()
        state.enabled = true
        state.loadSecrets(connectionId: UUID(), storage: makeStorage(.notFound))

        #expect(state.savedSecrets.isEmpty)
    }

    @Test("An edit through the shared SSH fields lands on the form state, secrets included")
    func sharedFieldsWriteThrough() {
        var state = SSHTunnelFormState()
        var server = state.server
        server.host = "bastion.example.com"
        server.port = "2222"
        server.authMethod = .privateKey
        server.keyPassphrase = "phrase"
        server.addJumpHost()
        state.server = server

        #expect(state.host == "bastion.example.com")
        #expect(state.port == "2222")
        #expect(state.authMethod == .privateKey)
        #expect(state.keyPassphrase == "phrase")
        #expect(state.jumpHosts.count == 1)
        #expect(state.server == server)
    }
}
