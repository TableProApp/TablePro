import Foundation
import TableProDatabase
import TableProModels
import Testing

@testable import TableProMobile

private struct KeychainLocked: Error {}

private final class RecordingSecureStore: SecureStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    var unreadableAccounts: Set<String> = []
    private(set) var changedAccounts: [String] = []

    func store(_ value: String, forKey key: String) throws {
        changedAccounts.append(key)
        storage[key] = value
    }

    func retrieve(forKey key: String) throws -> String? {
        guard !unreadableAccounts.contains(key) else { throw KeychainLocked() }
        return storage[key]
    }

    func delete(forKey key: String) throws {
        changedAccounts.append(key)
        storage.removeValue(forKey: key)
    }

    func seed(_ key: String, _ value: String) {
        storage[key] = value
    }

    func peek(_ key: String) -> String? {
        storage[key]
    }
}

@MainActor
struct ConnectionFormViewModelJumpHostTests {
    private let firstHop = SSHJumpHost(host: "bastion1.example.com", username: "ops")
    private let secondHop = SSHJumpHost(host: "bastion2.internal", port: 2_222, username: "ops")
    private let hopKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nhop\n-----END OPENSSH PRIVATE KEY-----\n"
    private let otherKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nother\n-----END OPENSSH PRIVATE KEY-----\n"

    private func chained(authMethod: SSHConfiguration.SSHAuthMethod = .privateKey) -> DatabaseConnection {
        DatabaseConnection(
            name: "Chain",
            type: .postgresql,
            host: "10.0.0.5",
            port: 5_432,
            sshEnabled: true,
            sshConfiguration: SSHConfiguration(
                host: "db-ssh.internal",
                username: "deploy",
                authMethod: authMethod,
                jumpHosts: [firstHop, secondHop]
            )
        )
    }

    private func account(_ connectionId: UUID) -> String {
        "com.TablePro.jumphostkeys.\(connectionId.uuidString)"
    }

    private func seed(_ credentials: [UUID: JumpHostCredential], for connectionId: UUID, in store: RecordingSecureStore) throws {
        let encoded = try JumpHostCredentialStore.encode(credentials)
        store.seed(account(connectionId), encoded)
    }

    private func stored(for connectionId: UUID, in store: RecordingSecureStore) throws -> [UUID: JumpHostCredential] {
        try JumpHostCredentialStore.load(for: connectionId, in: store)
    }

    private func loadedForm(_ connection: DatabaseConnection, store: RecordingSecureStore) async -> ConnectionFormViewModel {
        let form = ConnectionFormViewModel(editing: connection)
        await form.loadStoredCredentials(secureStore: store)
        return form
    }

    @Test("Editing a connection shows its hops and the key this device holds for each")
    func hydratesHopsAndKeys() async throws {
        let connection = chained()
        let store = RecordingSecureStore()
        try seed(
            [firstHop.id: .sshServerKey, secondHop.id: .privateKey(key: hopKey, passphrase: "unlock")],
            for: connection.id,
            in: store
        )

        let form = await loadedForm(connection, store: store)

        let hops = form.jumpHosts
        #expect(hops.count == 2)
        #expect(hops[0].id == firstHop.id)
        #expect(hops[0].host == "bastion1.example.com")
        #expect(hops[0].port.isEmpty)
        #expect(hops[0].usesServerKey)
        #expect(hops[1].port == "2222")
        #expect(hops[1].keyContent == hopKey)
        #expect(hops[1].keyPassphrase == "unlock")
        #expect(form.keyStatus(of: hops[0]) == .sameKey)
        #expect(form.keyStatus(of: hops[1]) == .ownKey)
        #expect(form.hasChanges == false)
        #expect(form.jumpHostCredentialsUnreadable == false)
    }

    @Test("Loading the stored keys again, as returning from a hop's screen does, keeps the form's edits")
    func secondLoadKeepsEdits() async throws {
        let connection = chained()
        let store = RecordingSecureStore()
        try seed([secondHop.id: .privateKey(key: hopKey, passphrase: nil)], for: connection.id, in: store)
        let form = await loadedForm(connection, store: store)

        form.updateJumpHost(secondHop.id) { $0.keyContent = otherKey }
        await form.loadStoredCredentials(secureStore: store)

        #expect(form.jumpHost(secondHop.id)?.keyContent == otherKey)
        #expect(form.hasChanges)
    }

    @Test("A hop with no key here, or on Same Key over a password tunnel, has no key on this device")
    func missingKeysAreReported() async throws {
        let connection = chained(authMethod: .password)
        let store = RecordingSecureStore()
        try seed([firstHop.id: .sshServerKey], for: connection.id, in: store)

        let form = await loadedForm(connection, store: store)

        let hops = form.jumpHosts
        #expect(form.keyStatus(of: hops[0]) == .noKey)
        #expect(form.keyStatus(of: hops[1]) == .noKey)
    }

    @Test("Keys set for hops are saved in the connection's jump host item")
    func savesHopKeys() async throws {
        let connection = chained()
        let store = RecordingSecureStore()
        let form = await loadedForm(connection, store: store)

        form.updateJumpHost(firstHop.id) { $0.usesServerKey = true }
        form.updateJumpHost(secondHop.id) {
            $0.keyContent = hopKey
            $0.keyPassphrase = "unlock"
        }
        try form.persistJumpHostCredentials(secureStore: store)

        let expected: [UUID: JumpHostCredential] = [
            firstHop.id: .sshServerKey,
            secondHop.id: .privateKey(key: hopKey, passphrase: "unlock")
        ]
        #expect(try stored(for: connection.id, in: store) == expected)
    }

    @Test("Removing a hop drops its key, and removing the last keyed hop deletes the item")
    func removingHopsDropsTheirKeys() async throws {
        let connection = chained()
        let store = RecordingSecureStore()
        try seed(
            [firstHop.id: .sshServerKey, secondHop.id: .privateKey(key: hopKey, passphrase: nil)],
            for: connection.id,
            in: store
        )
        let form = await loadedForm(connection, store: store)

        form.removeJumpHosts(atOffsets: IndexSet(integer: 0))
        try form.persistJumpHostCredentials(secureStore: store)
        let remaining: [UUID: JumpHostCredential] = [secondHop.id: .privateKey(key: hopKey, passphrase: nil)]
        #expect(try stored(for: connection.id, in: store) == remaining)

        form.removeJumpHosts(atOffsets: IndexSet(integer: 0))
        try form.persistJumpHostCredentials(secureStore: store)
        #expect(store.peek(account(connection.id)) == nil)
    }

    @Test("Turning SSH off deletes the jump host item")
    func sshOffDeletesTheItem() async throws {
        let connection = chained()
        let store = RecordingSecureStore()
        try seed([firstHop.id: .sshServerKey], for: connection.id, in: store)
        let form = await loadedForm(connection, store: store)

        form.sshEnabled = false
        try form.persistJumpHostCredentials(secureStore: store)

        #expect(store.peek(account(connection.id)) == nil)
    }

    @Test("Saving unchanged hop keys writes nothing")
    func unchangedKeysAreNotRewritten() async throws {
        let connection = chained()
        let store = RecordingSecureStore()
        try seed([firstHop.id: .sshServerKey], for: connection.id, in: store)
        let form = await loadedForm(connection, store: store)

        form.name = "Renamed"
        form.moveJumpHosts(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        try form.persistJumpHostCredentials(secureStore: store)

        #expect(store.changedAccounts.isEmpty)
    }

    @Test("A key another device stored for a hop this form does not show survives Save")
    func unshownHopKeySurvives() async throws {
        let connection = chained()
        let store = RecordingSecureStore()
        let elsewhere = UUID()
        try seed(
            [firstHop.id: .sshServerKey, elsewhere: .privateKey(key: otherKey, passphrase: nil)],
            for: connection.id,
            in: store
        )
        let form = await loadedForm(connection, store: store)
        let later = UUID()
        try seed(
            [
                firstHop.id: .sshServerKey,
                elsewhere: .privateKey(key: otherKey, passphrase: nil),
                later: .sshServerKey
            ],
            for: connection.id,
            in: store
        )

        let loadedIds = Set(form.storedSecrets.jumpHostCredentials.keys)
        #expect(loadedIds == Set([firstHop.id]))

        form.updateJumpHost(secondHop.id) { $0.keyContent = hopKey }
        try form.persistJumpHostCredentials(secureStore: store)

        let saved = try stored(for: connection.id, in: store)
        #expect(saved[elsewhere] == .privateKey(key: otherKey, passphrase: nil))
        #expect(saved[later] == .sshServerKey)
        #expect(saved[firstHop.id] == .sshServerKey)
        #expect(saved[secondHop.id] == .privateKey(key: hopKey, passphrase: nil))
    }

    @Test(
        "A key another device set for a hop this form left alone survives Save of another hop's key",
        arguments: [true, false]
    )
    func untouchedHopKeyFromElsewhereSurvives(hadKeyWhenOpened: Bool) async throws {
        let connection = chained()
        let store = RecordingSecureStore()
        if hadKeyWhenOpened {
            try seed([firstHop.id: .sshServerKey], for: connection.id, in: store)
        }
        let form = await loadedForm(connection, store: store)
        try seed([firstHop.id: .privateKey(key: otherKey, passphrase: nil)], for: connection.id, in: store)

        form.updateJumpHost(secondHop.id) { $0.keyContent = hopKey }
        try form.persistJumpHostCredentials(secureStore: store)

        let expected: [UUID: JumpHostCredential] = [
            firstHop.id: .privateKey(key: otherKey, passphrase: nil),
            secondHop.id: .privateKey(key: hopKey, passphrase: nil)
        ]
        #expect(try stored(for: connection.id, in: store) == expected)
    }

    @Test("An item that cannot be read turns off hop key edits, and Save after an edit leaves it untouched")
    func unreadableItemIsNeverWritten() async throws {
        let connection = chained()
        let store = RecordingSecureStore()
        try seed([firstHop.id: .sshServerKey], for: connection.id, in: store)
        let original = store.peek(account(connection.id))
        store.unreadableAccounts = [account(connection.id)]
        let fixture = try AppStateFixture()
        let appState = fixture.makeState(syncEnabled: false)
        #expect(appState.addConnection(connection))

        let form = await loadedForm(connection, store: store)
        #expect(form.jumpHostCredentialsUnreadable)
        #expect(form.credentialError != nil)
        #expect(form.hasChanges == false)

        form.dismissCredentialError()
        form.name = "Renamed"
        form.updateJumpHost(secondHop.id) { $0.keyContent = hopKey }
        _ = await form.save(appState: appState, secureStore: store)

        #expect(!store.changedAccounts.contains(account(connection.id)))
        #expect(store.peek(account(connection.id)) == original)
    }

    @Test("An item that cannot be read again at Save is left as it is, and the next Save stores the edit")
    func failedReReadKeepsTheItemAndRetries() async throws {
        let connection = chained()
        let store = RecordingSecureStore()
        try seed([firstHop.id: .sshServerKey], for: connection.id, in: store)
        let original = store.peek(account(connection.id))
        let form = await loadedForm(connection, store: store)
        store.unreadableAccounts = [account(connection.id)]

        form.updateJumpHost(secondHop.id) { $0.keyContent = hopKey }
        #expect(throws: (any Error).self) {
            try form.persistJumpHostCredentials(secureStore: store)
        }

        #expect(store.changedAccounts.isEmpty)
        #expect(store.peek(account(connection.id)) == original)
        #expect(form.hasChanges)

        store.unreadableAccounts = []
        try form.persistJumpHostCredentials(secureStore: store)

        let expected: [UUID: JumpHostCredential] = [
            firstHop.id: .sshServerKey,
            secondHop.id: .privateKey(key: hopKey, passphrase: nil)
        ]
        #expect(try stored(for: connection.id, in: store) == expected)
    }

    @Test("Test Connection hands the tunnel the hop keys under the throwaway id only")
    func testSecretsCarryHopKeys() async throws {
        let connection = chained()
        let store = RecordingSecureStore()
        try seed([firstHop.id: .sshServerKey], for: connection.id, in: store)
        let form = await loadedForm(connection, store: store)
        form.updateJumpHost(secondHop.id) { $0.keyContent = hopKey }
        let tempId = UUID()

        let secrets = form.testSecrets(for: tempId)
        let handed = try JumpHostCredentialStore.load(for: tempId, in: EphemeralSecureStore(secrets))

        let expected: [UUID: JumpHostCredential] = [
            firstHop.id: .sshServerKey,
            secondHop.id: .privateKey(key: hopKey, passphrase: nil)
        ]
        #expect(handed == expected)
        #expect(secrets.keys.allSatisfy { $0.hasSuffix(tempId.uuidString) })

        form.sshEnabled = false
        #expect(form.testSecrets(for: tempId)[account(tempId)] == nil)
    }

    @Test("A hop key edit is a change that reconnects after Save, and putting it back is not")
    func hopKeyEditsAreChanges() async throws {
        let connection = chained()
        let store = RecordingSecureStore()
        try seed([secondHop.id: .privateKey(key: hopKey, passphrase: nil)], for: connection.id, in: store)
        let form = await loadedForm(connection, store: store)

        form.updateJumpHost(secondHop.id) { $0.keyContent = otherKey }
        #expect(form.hasChanges)
        #expect(form.changesSecrets)
        #expect(form.reconnectsAfterSave)

        form.updateJumpHost(secondHop.id) { $0.keyContent = hopKey }
        #expect(form.hasChanges == false)
        #expect(form.reconnectsAfterSave == false)

        form.updateJumpHost(firstHop.id) { $0.host = "bastion1-new.example.com" }
        #expect(form.hasChanges)
    }

    @Test("Save stays off while a jump host has no host")
    func canSaveNeedsEveryHopHost() {
        let form = ConnectionFormViewModel()
        form.host = "10.0.0.5"
        form.sshEnabled = true
        #expect(form.canSave)

        let added = form.addJumpHost()
        #expect(form.canSave == false)

        form.updateJumpHost(added) { $0.host = "   " }
        #expect(form.canSave == false)

        form.updateJumpHost(added) { $0.host = "bastion.example.com" }
        #expect(form.canSave)

        form.updateJumpHost(added) { $0.host = "" }
        form.sshEnabled = false
        #expect(form.canSave)
    }

    @Test("Moving hops follows the list's drag order")
    func moveFollowsDragOrder() {
        let form = ConnectionFormViewModel(editing: chained())
        let third = form.addJumpHost()

        form.moveJumpHosts(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        let afterFirstMove = form.jumpHosts.map { $0.id }
        #expect(afterFirstMove == [secondHop.id, third, firstHop.id])

        form.moveJumpHosts(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        let afterSecondMove = form.jumpHosts.map { $0.id }
        #expect(afterSecondMove == [firstHop.id, secondHop.id, third])
    }

    @Test("A picked text key file fills the hop's key, and a file that is not text is refused")
    func pickedKeyFile() throws {
        let fixture = try AppStateFixture()
        let form = fixture.makeFormViewModel(editing: chained())
        let textKey = fixture.root.appendingPathComponent("id_ed25519")
        try Data(hopKey.utf8).write(to: textKey)
        let binaryKey = fixture.root.appendingPathComponent("id_binary")
        try Data([0xFF, 0xFE, 0x00, 0x81]).write(to: binaryKey)

        form.updateJumpHost(firstHop.id) { $0.usesServerKey = true }
        #expect(form.importJumpHostKey(.success([textKey]), for: firstHop.id))
        #expect(form.jumpHost(firstHop.id)?.keyContent == hopKey)
        #expect(form.jumpHost(firstHop.id)?.usesServerKey == false)

        #expect(form.importJumpHostKey(.success([binaryKey]), for: secondHop.id) == false)
        #expect(form.jumpHostKeyFileError != nil)
        #expect(form.jumpHost(secondHop.id)?.keyContent.isEmpty == true)
    }
}
