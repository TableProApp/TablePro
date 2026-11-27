import Combine
import Foundation
import TableProFFI
@testable import TableProMobile
import TableProTestSupport
import Testing

// On TablePro Sync the iCloud Keychain items stay for the devices still on iCloud, and this device keeps its own.
struct KeychainTableProSyncTests {
    private let items = InMemoryKeychainItems()
    private let account = ConnectionSecretKind.password.account(for: UUID())
    private let provider: DefaultsKeychainProviderRecord

    init() throws {
        let defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.KeychainSync.\(UUID().uuidString)"))
        provider = DefaultsKeychainProviderRecord(defaults: defaults)
        provider.store(KeychainProviderState(onTableProSync: true, deviceCopiesAdded: false))
    }

    // Password sync on, as it was on iCloud: on TablePro Sync it no longer decides.
    private var store: KeychainSecureStore {
        KeychainSecureStore(syncsPasswords: { true }, provider: provider, items: items)
    }

    @Test("A save on TablePro Sync goes to this device's item and leaves the iCloud one as it was")
    func saveStaysOnThisDevice() throws {
        items.seed("from-icloud", account: account, synchronizable: true)

        try store.store("from-phone", forKey: account)

        #expect(items.value(account: account, synchronizable: false) == "from-phone")
        #expect(items.value(account: account, synchronizable: true) == "from-icloud")
        #expect(try store.retrieve(forKey: account) == "from-phone")
    }

    @Test("A removal on TablePro Sync leaves the iCloud item, and its value never reads back")
    func removalKeepsTheICloudItem() throws {
        items.seed("from-icloud", account: account, synchronizable: true)
        try store.store("from-phone", forKey: account)

        try store.delete(forKey: account)

        #expect(items.value(account: account, synchronizable: true) == "from-icloud")
        #expect(items.value(account: account, synchronizable: false) == nil)
        #expect(try store.retrieve(forKey: account) == nil)
        // Nor does a later copy bring it back.
        #expect(store.addDeviceOnlyCopies())
        #expect(items.value(account: account, synchronizable: false) == nil)
    }

    @Test("Each iCloud item gets a copy of this device's own, which reads after the copies are marked done")
    func copiesAreAdded() throws {
        items.seed("from-icloud", account: account, synchronizable: true)

        #expect(store.addDeviceOnlyCopies())
        provider.store(KeychainProviderState(onTableProSync: true, deviceCopiesAdded: true))

        #expect(items.value(account: account, synchronizable: false) == "from-icloud")
        #expect(try store.retrieve(forKey: account) == "from-icloud")
    }

    @Test("A Keychain that refuses the listing, as before the first unlock, never counts as every copy made")
    func refusedListingIsNotComplete() {
        items.seed("from-icloud", account: account, synchronizable: true)
        items.failedListing = errSecInteractionNotAllowed

        #expect(!store.addDeviceOnlyCopies())
        #expect(items.value(account: account, synchronizable: false) == nil)
    }

    @Test("Off TablePro Sync again, a removal reaches the iCloud item as before")
    func offTableProSyncRemovesBoth() throws {
        provider.store(.followsPasswordSync)
        items.seed("from-icloud", account: account, synchronizable: true)

        try store.delete(forKey: account)

        #expect(items.value(account: account, synchronizable: true) == nil)
    }

    @MainActor
    @Test("The follower marks the copies done once the engine reports TablePro Sync, and forgets them back on iCloud")
    func followerTracksTheProvider() async throws {
        provider.store(.followsPasswordSync)
        items.seed("from-icloud", account: account, synchronizable: true)
        let keychain = store
        let changes = PassthroughSubject<Void, Never>()
        var reported: SyncProviderTag? = .tableproSync
        let follower = KeychainProviderFollower(addCopies: { keychain.addDeviceOnlyCopies() }, record: provider)
        follower.start(changes: changes.eraseToAnyPublisher()) { reported }

        changes.send()
        await follower.copiesSettled()
        #expect(provider.state == KeychainProviderState(onTableProSync: true, deviceCopiesAdded: true))
        #expect(items.value(account: account, synchronizable: false) == "from-icloud")

        reported = .icloud
        changes.send()
        #expect(provider.state == .followsPasswordSync)
    }
}
