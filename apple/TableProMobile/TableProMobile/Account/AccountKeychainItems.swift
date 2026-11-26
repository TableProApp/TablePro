import Foundation
import Security

// The account's Keychain items: this device only, readable once the device was first unlocked, so a background
// refresh can read them, and in the app's own access group, never the one the widget shares.
nonisolated struct AccountKeychainItems: Sendable {
    static let service = "com.TablePro"
    static let deviceIDItem = "com.TablePro.account.deviceID"

    let items: any KeychainItemStore
    let accessGroup: String?

    init(items: any KeychainItemStore = SystemKeychainItemStore(), accessGroup: String? = Self.appAccessGroup) {
        self.items = items
        self.accessGroup = accessGroup
    }

    // The application identifier, which the system adds to the app's access groups; without a set group an item
    // would join the first group the entitlements list, the widget's.
    static var appAccessGroup: String? {
        guard let prefix = Bundle.main.infoDictionary?["AppIdentifierPrefix"] as? String, !prefix.isEmpty,
              !prefix.hasPrefix("$("), let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return prefix + bundleID
    }

    func read(_ account: String) throws(AccountKeychainFailure) -> Data? {
        let found = items.copyItem(query(account))
        switch found.status {
        case errSecSuccess:
            return found.data
        case errSecItemNotFound:
            return nil
        default:
            throw Self.failure(found.status)
        }
    }

    func write(_ data: Data, to account: String) throws(AccountKeychainFailure) {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = items.update(query(account), attributes: attributes)
        if status == errSecItemNotFound {
            status = items.add(query(account).merging(attributes) { _, new in new })
        }
        guard status == errSecSuccess else { throw Self.failure(status) }
    }

    // Adds only when absent: two launches racing for a first device ID keep the one written first.
    func add(_ data: Data, to account: String) throws(AccountKeychainFailure) -> Bool {
        var attributes = query(account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = items.add(attributes)
        switch status {
        case errSecSuccess: return true
        case errSecDuplicateItem: return false
        default: throw Self.failure(status)
        }
    }

    func delete(_ account: String) {
        _ = items.delete(query(account))
    }

    private func query(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private static func failure(_ status: OSStatus) -> AccountKeychainFailure {
        switch status {
        case errSecInteractionNotAllowed: .locked
        case errSecUserCanceled: .dismissed
        default: .failed("Keychain error \(status)")
        }
    }
}

// The refresh tokens the core keeps, one item per server, named as on the Mac.
nonisolated struct MobileAccountKeychain: AccountTokenKeychain {
    let items: AccountKeychainItems

    func refreshToken(signInKey: String?) throws(AccountKeychainFailure) -> String? {
        guard let data = try items.read(AccountRefreshTokenItem.key(signInKey: signInKey)) else { return nil }
        let token = String(data: data, encoding: .utf8) ?? ""
        return token.isEmpty ? nil : token
    }

    func storeRefreshToken(_ token: String, signInKey: String?) throws(AccountKeychainFailure) {
        try items.write(Data(token.utf8), to: AccountRefreshTokenItem.key(signInKey: signInKey))
    }

    func deleteRefreshToken(signInKey: String?) {
        items.delete(AccountRefreshTokenItem.key(signInKey: signInKey))
    }
}

// The machine ID the account registers this device under: 32 random bytes made the first time the account opens. A
// backup restored to another device brings no item of this device's, so that device gets an ID of its own.
nonisolated enum AccountDeviceID {
    static func current(
        items: AccountKeychainItems,
        random: () -> Data? = randomBytes
    ) throws(AccountKeychainFailure) -> String {
        let stored = try items.read(AccountKeychainItems.deviceIDItem)
        if let stored, stored.count == 32 {
            return hex(stored)
        }
        guard let fresh = random(), fresh.count == 32 else {
            throw .failed("no random bytes for a device ID")
        }
        // An item of another length is no ID this app wrote, so it is replaced.
        if stored != nil {
            try items.write(fresh, to: AccountKeychainItems.deviceIDItem)
            return hex(fresh)
        }
        if try items.add(fresh, to: AccountKeychainItems.deviceIDItem) {
            return hex(fresh)
        }
        guard let stored = try items.read(AccountKeychainItems.deviceIDItem), stored.count == 32 else {
            throw .failed("the device ID another launch wrote does not read")
        }
        return hex(stored)
    }

    static func randomBytes() -> Data? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
