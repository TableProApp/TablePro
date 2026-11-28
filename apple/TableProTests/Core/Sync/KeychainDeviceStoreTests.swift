import Foundation
import os
import Security
@testable import TablePro
import TableProFFI
import Testing

// The Keychain's own rule for which item a query names: service, account, access group and synchronizable.
private final class FakeDeviceKeychain: DeviceKeychainItems, @unchecked Sendable {
    struct Identity: Hashable {
        let service: String
        let account: String
        let accessGroup: String?
        let synchronizable: Bool
    }

    struct State {
        var items: [Identity: [String: Any]] = [:]
        var failure: OSStatus?
        var answersWithoutData = false
    }

    let state = OSAllocatedUnfairLock(uncheckedState: State())

    var items: [Identity: [String: Any]] {
        state.withLockUnchecked { $0.items }
    }

    func fail(with status: OSStatus?) {
        state.withLockUnchecked { $0.failure = status }
    }

    func plant(_ attributes: [String: Any]) {
        state.withLockUnchecked { $0.items[Self.identity(attributes)] = attributes }
    }

    static func identity(_ query: [String: Any]) -> Identity {
        Identity(
            service: query[kSecAttrService as String] as? String ?? "",
            account: query[kSecAttrAccount as String] as? String ?? "",
            accessGroup: query[kSecAttrAccessGroup as String] as? String,
            synchronizable: query[kSecAttrSynchronizable as String] as? Bool ?? false
        )
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        state.withLockUnchecked { state in
            if let failure = state.failure { return failure }
            let identity = Self.identity(attributes)
            guard state.items[identity] == nil else { return errSecDuplicateItem }
            state.items[identity] = attributes
            return errSecSuccess
        }
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        state.withLockUnchecked { state in
            if let failure = state.failure { return failure }
            let identity = Self.identity(query)
            guard let item = state.items[identity] else { return errSecItemNotFound }
            state.items[identity] = item.merging(attributes) { _, new in new }
            return errSecSuccess
        }
    }

    func copyData(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        state.withLockUnchecked { state in
            if let failure = state.failure { return (failure, nil) }
            guard let item = state.items[Self.identity(query)] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, state.answersWithoutData ? nil : item[kSecValueData as String] as? Data)
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        state.withLockUnchecked { state in
            if let failure = state.failure { return failure }
            return state.items.removeValue(forKey: Self.identity(query)) == nil ? errSecItemNotFound : errSecSuccess
        }
    }
}

struct KeychainDeviceStoreTests {
    private static let group = "TEAMID.com.TablePro.shared"
    private static let origin = "https://api.tablepro.app"
    private static let keys: [DeviceItemTag] = [
        .deviceKeys(origin: origin, account: "ACCOUNT", deviceRow: "ROW"),
        .accountKeys(origin: origin, account: "ACCOUNT", av: 3),
        .resetKeys(origin: origin, account: "ACCOUNT", reset: "RESET")
    ]
    private static let anchor: [DeviceItemTag] = [
        .stateMacKey(state: "STATE"),
        .anchorRoot(state: "STATE"),
        .anchorCheckpoint(state: "STATE", checkpoint: "0a1b", part: 0)
    ]

    private let keychain = FakeDeviceKeychain()

    private func store(passcode: Bool = true) -> KeychainDeviceStore {
        KeychainDeviceStore(items: keychain, accessGroup: Self.group, passcodeIsSet: { passcode })
    }

    private func written(_ item: DeviceItemTag) throws -> [String: Any] {
        let account = KeychainDeviceStore.account(item)
        return try #require(keychain.items.first { $0.key.account == account }?.value)
    }

    @Test("Every item stays on this device: the data protection keychain, never synchronizable, in the app's group")
    func itemsNeverSync() throws {
        let store = store()
        for item in Self.keys + Self.anchor {
            try store.store(item: item, value: Data([1, 2, 3]))
        }

        #expect(keychain.items.count == 6)
        for (identity, attributes) in keychain.items {
            #expect(!identity.synchronizable)
            #expect(identity.service == KeychainDeviceStore.service)
            #expect(identity.accessGroup == Self.group)
            #expect(attributes[kSecUseDataProtectionKeychain as String] as? Bool == true)
            #expect(attributes[kSecClass as String] as? String == kSecClassGenericPassword as String)
        }
    }

    @Test("Keys are readable after first unlock; the anchor and the state MAC key only while a passcode is set")
    func eachClassHasItsAccessibility() throws {
        let store = store()
        for item in Self.keys + Self.anchor {
            try store.store(item: item, value: Data([7]))
        }

        for item in Self.keys {
            #expect(try written(item)[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        }
        for item in Self.anchor {
            #expect(try written(item)[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String)
        }
    }

    @Test("With no passcode the anchor takes the keys' class, and moves to the passcode's at its next write once one is set")
    func anchorWithoutAPasscode() throws {
        let root = DeviceItemTag.anchorRoot(state: "STATE")
        try store(passcode: false).store(item: root, value: Data([1]))
        #expect(try written(root)[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

        try store(passcode: true).store(item: root, value: Data([2]))

        #expect(keychain.items.count == 1)
        #expect(try written(root)[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String)
        #expect(try store().load(item: root) == Data([2]))
    }

    @Test("The Keychain is always there, so the core never opens a state file without an anchor here")
    func alwaysPresent() {
        #expect(store().present())
    }

    @Test("What is stored reads back and is replaced in place, a missing item reads as nil, and deleting one not there succeeds")
    func storeLoadDelete() throws {
        let store = store()
        let key = DeviceItemTag.stateMacKey(state: "STATE")
        #expect(try store.load(item: key) == nil)

        try store.store(item: key, value: Data([1]))
        try store.store(item: key, value: Data([2]))
        #expect(try store.load(item: key) == Data([2]))
        #expect(keychain.items.count == 1)

        try store.delete(item: key)
        #expect(try store.load(item: key) == nil)
        try store.delete(item: key)
    }

    @Test("A synced item of the same name is never read, written over or deleted")
    func aSyncedItemIsLeftAlone() throws {
        let item = DeviceItemTag.anchorRoot(state: "STATE")
        keychain.plant([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainDeviceStore.service,
            kSecAttrAccount as String: KeychainDeviceStore.account(item),
            kSecAttrAccessGroup as String: Self.group,
            kSecAttrSynchronizable as String: true,
            kSecValueData as String: Data([9])
        ])
        let store = store()

        #expect(try store.load(item: item) == nil)
        try store.store(item: item, value: Data([1]))
        try store.delete(item: item)

        #expect(keychain.items.count == 1)
        #expect(keychain.items.keys.first?.synchronizable == true)
        #expect(keychain.items.values.first?[kSecValueData as String] as? Data == Data([9]))
    }

    @Test("A locked Keychain refuses every call, and never reads as a missing item")
    func lockedRefuses() throws {
        let store = store()
        let item = DeviceItemTag.anchorRoot(state: "STATE")
        try store.store(item: item, value: Data([1]))
        keychain.fail(with: errSecInteractionNotAllowed)

        #expect(throws: HostSecretError.Locked) { try store.load(item: item) }
        #expect(throws: HostSecretError.Locked) { try store.store(item: item, value: Data([2])) }
        #expect(throws: HostSecretError.Locked) { try store.delete(item: item) }
    }

    @Test("An item the Keychain holds but cannot give is an error, never a missing item")
    func unreadableIsAnError() throws {
        let store = store()
        let item = DeviceItemTag.deviceKeys(origin: Self.origin, account: "ACCOUNT", deviceRow: "ROW")
        try store.store(item: item, value: Data([1]))

        keychain.fail(with: errSecMissingEntitlement)
        #expect(throws: HostSecretError.Unavailable(detail: "Keychain error \(errSecMissingEntitlement)")) {
            try store.load(item: item)
        }
        keychain.fail(with: errSecDecode)
        #expect(throws: HostSecretError.Failed(detail: "Keychain error \(errSecDecode)")) { try store.load(item: item) }
        keychain.fail(with: nil)
        keychain.state.withLockUnchecked { $0.answersWithoutData = true }
        #expect(throws: HostSecretError.Failed(detail: "the device item holds no data")) { try store.load(item: item) }
    }

    @Test("Under a sandbox the device items stay in its file, never the Keychain the installation reads")
    func sandboxKeepsItsOwnItems() {
        let environment = AppStorageEnvironment.shared
        #expect(environment.isIsolated == (environment.deviceItems is SandboxDeviceKeychainItems))
    }

    @Test("The sandbox's items read back, are replaced and deleted, and a file that does not read is an error")
    func sandboxItems() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeychainDeviceStoreTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = KeychainDeviceStore(items: SandboxDeviceKeychainItems(fileURL: file), accessGroup: nil, passcodeIsSet: { true })
        let root = DeviceItemTag.anchorRoot(state: "STATE")
        let key = DeviceItemTag.stateMacKey(state: "STATE")

        #expect(try store.load(item: root) == nil)
        try store.store(item: root, value: Data([1]))
        try store.store(item: root, value: Data([2]))
        try store.store(item: key, value: Data([3]))
        #expect(try store.load(item: root) == Data([2]))
        try store.delete(item: root)
        #expect(try store.load(item: root) == nil)
        #expect(try store.load(item: key) == Data([3]))

        try Data("not json".utf8).write(to: file)
        #expect(throws: HostSecretError.Failed(detail: "Keychain error \(errSecDecode)")) { try store.load(item: key) }
        #expect(throws: HostSecretError.Failed(detail: "Keychain error \(errSecDecode)")) {
            try store.store(item: key, value: Data([4]))
        }
        #expect(try Data(contentsOf: file) == Data("not json".utf8))
    }

    @Test("Each item has a name of its own, whatever its parts hold")
    func namesDoNotCollide() {
        let items: [DeviceItemTag] = Self.keys + Self.anchor + [
            .deviceKeys(origin: "https://a/b", account: "c", deviceRow: "d"),
            .deviceKeys(origin: "https://a", account: "b/c", deviceRow: "d"),
            .anchorCheckpoint(state: "STATE", checkpoint: "0a1b", part: 1),
            .accountKeys(origin: Self.origin, account: "ACCOUNT", av: 4)
        ]

        #expect(Set(items.map(KeychainDeviceStore.account)).count == items.count)
    }
}
