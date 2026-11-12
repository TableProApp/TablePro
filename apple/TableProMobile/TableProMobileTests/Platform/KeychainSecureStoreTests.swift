import Foundation
import os
import Security
@testable import TableProMobile
import Testing

struct KeychainSecureStoreTests {
    private let items = InMemoryKeychainItems()
    private let account = ConnectionSecretKind.password.account(for: UUID())

    private func secureStore(syncsPasswords: Bool) -> KeychainSecureStore {
        KeychainSecureStore(syncsPasswords: { syncsPasswords }, items: items)
    }

    @Test("Saving with Sync Passwords off keeps the synced copy another device reads")
    func deviceOnlySaveKeepsTheSyncedCopy() throws {
        items.seed("from-mac", account: account, synchronizable: true)

        try secureStore(syncsPasswords: false).store("from-phone", forKey: account)
        try secureStore(syncsPasswords: false).store("from-phone-again", forKey: account)

        #expect(items.value(account: account, synchronizable: true) == "from-mac")
        #expect(items.value(account: account, synchronizable: false) == "from-phone-again")
        #expect(try secureStore(syncsPasswords: false).retrieve(forKey: account) == "from-phone-again")
    }

    @Test("Saving with Sync Passwords on updates the synced copy in place and drops the device-only one")
    func syncedSaveUpdatesInPlace() throws {
        items.seed("old", account: account, synchronizable: true)
        items.seed("local", account: account, synchronizable: false)

        try secureStore(syncsPasswords: true).store("new", forKey: account)

        #expect(items.value(account: account, synchronizable: true) == "new")
        #expect(items.value(account: account, synchronizable: false) == nil)
        #expect(items.accessibility(account: account, synchronizable: true) == kSecAttrAccessibleAfterFirstUnlock as String)
    }

    @Test("A save the Keychain refuses leaves every stored copy as it was")
    func refusedSaveLosesNothing() throws {
        items.seed("from-mac", account: account, synchronizable: true)
        items.failedAdd = errSecInteractionNotAllowed

        #expect(throws: KeychainError.self) {
            try secureStore(syncsPasswords: false).store("from-phone", forKey: account)
        }
        #expect(items.value(account: account, synchronizable: true) == "from-mac")
        #expect(try secureStore(syncsPasswords: false).retrieve(forKey: account) == "from-mac")

        items.failedAdd = nil
        items.seed("local", account: account, synchronizable: false)
        items.failedUpdate = errSecInteractionNotAllowed

        #expect(throws: KeychainError.self) {
            try secureStore(syncsPasswords: true).store("new", forKey: account)
        }
        #expect(items.value(account: account, synchronizable: true) == "from-mac")
        #expect(items.value(account: account, synchronizable: false) == "local")
    }

    @Test("A read finds the copy the setting does not select when it is the only one")
    func readFallsBackToTheOtherCopy() throws {
        items.seed("from-mac", account: account, synchronizable: true)
        #expect(try secureStore(syncsPasswords: false).retrieve(forKey: account) == "from-mac")
    }

    @Test("With Sync Passwords on the newer copy is read; with it off this device's own copy is")
    func readReturnsTheNewerCopy() throws {
        items.seed("from-mac", account: account, synchronizable: true)
        items.seed("from-phone", account: account, synchronizable: false)

        #expect(try secureStore(syncsPasswords: false).retrieve(forKey: account) == "from-phone")
        #expect(try secureStore(syncsPasswords: true).retrieve(forKey: account) == "from-phone")

        items.seed("changed-on-mac", account: account, synchronizable: true)

        #expect(try secureStore(syncsPasswords: false).retrieve(forKey: account) == "from-phone")
        #expect(try secureStore(syncsPasswords: true).retrieve(forKey: account) == "changed-on-mac")
    }

    @Test("A password saved with Sync Passwords off is the one read once it is back on")
    func deviceOnlySaveSurvivesTurningSyncBackOn() throws {
        items.seed("from-mac", account: account, synchronizable: true)

        try secureStore(syncsPasswords: false).store("from-phone", forKey: account)

        #expect(try secureStore(syncsPasswords: true).retrieve(forKey: account) == "from-phone")
        #expect(items.value(account: account, synchronizable: true) == "from-mac")
    }

    @Test("A device-only sign-in key reads this device's copy over a newer synced one")
    func deviceOnlyKeyReadsItsOwnCopy() throws {
        let deviceKey = ConnectionSecretKind.deviceIAM.account(for: UUID())
        items.seed("own", account: deviceKey, synchronizable: false)
        items.seed("synced", account: deviceKey, synchronizable: true)

        #expect(try secureStore(syncsPasswords: true).retrieve(forKey: deviceKey) == "own")
    }

    @Test("A device-only sign-in key is written to this device alone with Sync Passwords on")
    func deviceOnlyKeyStaysOnTheDevice() throws {
        let deviceKey = ConnectionSecretKind.deviceIAM.account(for: UUID())

        try secureStore(syncsPasswords: true).store("key", forKey: deviceKey)

        #expect(items.value(account: deviceKey, synchronizable: false) == "key")
        #expect(items.value(account: deviceKey, synchronizable: true) == nil)
    }

    @Test("A certificate save the Keychain refuses keeps the certificate already stored")
    func refusedCertificateSaveKeepsTheOldOne() throws {
        let store = CertificateMaterialStore(items: items)
        let connectionId = UUID()
        try store.store("old-pem", role: .clientCertificate, for: connectionId)

        items.failedUpdate = errSecInteractionNotAllowed
        #expect(throws: CertificateStoreError.self) {
            try store.store("new-pem", role: .clientCertificate, for: connectionId)
        }
        #expect(store.pem(role: .clientCertificate, for: connectionId) == "old-pem")

        items.failedUpdate = nil
        try store.store("new-pem", role: .clientCertificate, for: connectionId)
        #expect(store.pem(role: .clientCertificate, for: connectionId) == "new-pem")
    }

    // MARK: - Launch cleanup

    @Test("The launch cleanup removes a deleted connection's device-only secrets and keeps current, synced and Mac-owned ones")
    func cleanupRemovesOnlyOrphans() async {
        let kept = UUID()
        let deleted = UUID()
        let keptPassword = ConnectionSecretKind.password.account(for: kept)
        let deletedPassword = ConnectionSecretKind.password.account(for: deleted)
        let deletedSSHPassword = ConnectionSecretKind.sshPassword.account(for: deleted)
        let macOwnedKey = ConnectionSecretKind.sshPrivateKey.account(for: deleted)
        items.seed("kept", account: keptPassword, synchronizable: false)
        items.seed("orphan", account: deletedPassword, synchronizable: false)
        items.seed("orphan", account: deletedSSHPassword, synchronizable: false)
        items.seed("synced", account: deletedPassword, synchronizable: true)
        items.seed("mac", account: macOwnedKey, synchronizable: false)

        await KeychainSecureStore.cleanOrphanedCredentials(items: items) { Set([kept]) }

        #expect(items.value(account: keptPassword, synchronizable: false) == "kept")
        #expect(items.value(account: deletedPassword, synchronizable: false) == nil)
        #expect(items.value(account: deletedSSHPassword, synchronizable: false) == nil)
        #expect(items.value(account: deletedPassword, synchronizable: true) == "synced")
        #expect(items.value(account: macOwnedKey, synchronizable: false) == "mac")
    }

    @MainActor
    @Test("Started from the main actor, the launch cleanup makes no Keychain call on the main thread")
    func cleanupStaysOffTheMainThread() async {
        let orphan = ConnectionSecretKind.password.account(for: UUID())
        items.seed("orphan", account: orphan, synchronizable: false)

        await KeychainSecureStore.cleanOrphanedCredentials(items: items) { Set([UUID()]) }

        #expect(items.value(account: orphan, synchronizable: false) == nil)
        #expect(items.mainThreadCalls == 0)
    }

    @Test("A connection saved while the Keychain is listed keeps its secrets, since the library is read after the listing")
    func connectionSavedDuringListingKeepsItsSecrets() async {
        let existing = UUID()
        let saved = UUID()
        let savedPassword = ConnectionSecretKind.password.account(for: saved)
        let library = OSAllocatedUnfairLock(initialState: Set([existing]))
        items.duringNextListing { [items] in
            // A save adds the connection, then writes its secrets.
            library.withLock { _ = $0.insert(saved) }
            items.seed("new", account: savedPassword, synchronizable: false)
        }

        await KeychainSecureStore.cleanOrphanedCredentials(items: items) { library.withLock { $0 } }

        #expect(items.value(account: savedPassword, synchronizable: false) == "new")
    }

    @Test("A library that is empty or not loaded removes nothing")
    func unknownLibraryRemovesNothing() async {
        let account = ConnectionSecretKind.password.account(for: UUID())
        items.seed("secret", account: account, synchronizable: false)

        await KeychainSecureStore.cleanOrphanedCredentials(items: items) { nil }
        await KeychainSecureStore.cleanOrphanedCredentials(items: items) { Set() }

        #expect(items.value(account: account, synchronizable: false) == "secret")
    }
}
