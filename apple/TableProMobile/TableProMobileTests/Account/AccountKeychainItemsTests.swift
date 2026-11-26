import Foundation
import Security
@testable import TableProMobile
import Testing

// A Keychain whose reads fail as a locked device's do before its first unlock.
private final class LockedKeychainItems: KeychainItemStore, @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0

    var writeCount: Int { lock.withLock { writes } }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock { writes += 1 }
        return errSecInteractionNotAllowed
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.withLock { writes += 1 }
        return errSecInteractionNotAllowed
    }

    func copyItem(_ query: [String: Any]) -> KeychainCopiedItem {
        KeychainCopiedItem(status: errSecInteractionNotAllowed, data: nil, modified: nil)
    }

    func accounts(_ query: [String: Any]) -> [String] { [] }

    func delete(_ query: [String: Any]) -> OSStatus { errSecInteractionNotAllowed }
}

struct AccountDeviceIDTests {
    @Test("The first open makes 32 random bytes, kept on this device only, and every later open reads them back")
    func madeOnceAndKept() throws {
        let keychain = InMemoryKeychainItems()
        let items = AccountKeychainItems(items: keychain, accessGroup: nil)
        let bytes = Data((0..<32).map { UInt8($0) })

        let first = try AccountDeviceID.current(items: items) { bytes }
        let second = try AccountDeviceID.current(items: items) { Data(repeating: 0xff, count: 32) }

        #expect(first == "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        #expect(second == first)
        #expect(
            keychain.accessibility(account: AccountKeychainItems.deviceIDItem, synchronizable: false)
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        #expect(keychain.value(account: AccountKeychainItems.deviceIDItem, synchronizable: true) == nil)
    }

    @Test("A locked Keychain is no missing ID: nothing is made, and the open waits for the unlock")
    func lockedWritesNothing() {
        let keychain = LockedKeychainItems()
        let items = AccountKeychainItems(items: keychain, accessGroup: nil)

        #expect(throws: AccountKeychainFailure.locked) {
            try AccountDeviceID.current(items: items) { Data(repeating: 1, count: 32) }
        }
        #expect(keychain.writeCount == 0)
    }

    @Test("An item of another length is replaced by a new ID")
    func wrongLengthIsReplaced() throws {
        let keychain = InMemoryKeychainItems()
        keychain.seed("short", account: AccountKeychainItems.deviceIDItem, synchronizable: false)
        let items = AccountKeychainItems(items: keychain, accessGroup: nil)

        let id = try AccountDeviceID.current(items: items) { Data(repeating: 0xab, count: 32) }

        #expect(id == String(repeating: "ab", count: 32))
        #expect(try AccountDeviceID.current(items: items) { nil } == id)
    }
}

struct MobileAccountKeychainTests {
    @Test("tablepro.app's refresh token and each company server's get the Mac's item names, on this device only")
    func itemsPerServer() throws {
        let keychain = InMemoryKeychainItems()
        let tokens = MobileAccountKeychain(items: AccountKeychainItems(items: keychain, accessGroup: nil))

        try tokens.storeRefreshToken("production-token", signInKey: nil)
        try tokens.storeRefreshToken("company-token", signInKey: "a1b2")

        #expect(try tokens.refreshToken(signInKey: nil) == "production-token")
        #expect(try tokens.refreshToken(signInKey: "a1b2") == "company-token")
        #expect(keychain.value(account: "com.TablePro.account.refreshToken", synchronizable: false) == "production-token")
        #expect(keychain.value(account: "com.TablePro.account.refreshToken.a1b2", synchronizable: false) == "company-token")

        tokens.deleteRefreshToken(signInKey: "a1b2")

        #expect(try tokens.refreshToken(signInKey: "a1b2") == nil)
        #expect(try tokens.refreshToken(signInKey: nil) == "production-token")
    }

    @Test("A rotated token replaces the one before")
    func rotationReplaces() throws {
        let tokens = MobileAccountKeychain(items: AccountKeychainItems(items: InMemoryKeychainItems(), accessGroup: nil))

        try tokens.storeRefreshToken("first", signInKey: nil)
        try tokens.storeRefreshToken("second", signInKey: nil)

        #expect(try tokens.refreshToken(signInKey: nil) == "second")
    }

    @Test("A locked Keychain reaches the core as locked, so it keeps the sign-in for the next try")
    func lockedIsLocked() {
        let tokens = MobileAccountKeychain(items: AccountKeychainItems(items: LockedKeychainItems(), accessGroup: nil))

        #expect(throws: AccountKeychainFailure.locked) { try tokens.refreshToken(signInKey: nil) }
        #expect(throws: AccountKeychainFailure.locked) { try tokens.storeRefreshToken("token", signInKey: nil) }
    }
}
