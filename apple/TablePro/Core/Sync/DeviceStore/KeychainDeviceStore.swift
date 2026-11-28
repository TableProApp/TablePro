//
//  KeychainDeviceStore.swift
//  TablePro
//

import Foundation
import LocalAuthentication
import Security
import TableProFFI

// The Keychain calls the device store makes, so its tests read what each item is written with.
nonisolated protocol DeviceKeychainItems: Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func copyData(_ query: [String: Any]) -> (status: OSStatus, data: Data?)
    func delete(_ query: [String: Any]) -> OSStatus
}

nonisolated struct SystemDeviceKeychainItems: DeviceKeychainItems {
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func copyData(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

// The core's device store in the Apple apps (core ADR 0054, Integrity and freshness): the device, account and reset
// keys, and each state file's MAC key and anchor, as items of the data protection keychain that never sync. The
// anchor's class stays out of backups and goes with the passcode, so a restored state file cannot bring its anchor
// back; a device with no passcode keeps it in the keys' class, which a backup restores to the same device only.
nonisolated final class KeychainDeviceStore: HostDeviceStore, @unchecked Sendable {
    static let service = "com.TablePro.sync.device"

    private let items: any DeviceKeychainItems
    private let accessGroup: String?
    private let passcodeIsSet: @Sendable () -> Bool

    init(
        items: any DeviceKeychainItems = SystemDeviceKeychainItems(),
        accessGroup: String?,
        passcodeIsSet: @escaping @Sendable () -> Bool = KeychainDeviceStore.devicePasscodeIsSet
    ) {
        self.items = items
        self.accessGroup = accessGroup
        self.passcodeIsSet = passcodeIsSet
    }

    // Only a missing item is nil: one the Keychain holds but cannot give, locked or unreadable, is an error, since
    // the engine would take a missing anchor for a file to trust less and a missing key for a new device.
    func load(item: DeviceItemTag) throws -> Data? {
        var query = query(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let found = items.copyData(query)
        switch found.status {
        case errSecSuccess:
            guard let data = found.data else {
                throw HostSecretError.Failed(detail: "the device item holds no data")
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw Self.error(found.status)
        }
    }

    // The class is chosen at each write, so an anchor written before a passcode was set moves into the passcode's
    // class at its next write.
    func store(item: DeviceItemTag, value: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: accessibility(of: item)
        ]
        var status = items.update(query(item), attributes: attributes)
        if status == errSecItemNotFound {
            status = items.add(query(item).merging(attributes) { _, new in new })
        }
        guard status == errSecSuccess else { throw Self.error(status) }
    }

    func delete(item: DeviceItemTag) throws {
        let status = items.delete(query(item))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
    }

    // An Apple device always has the Keychain. One that cannot answer now, locked or missing the entitlement, says so
    // per item, so the core waits for it instead of opening a state file with no anchor.
    func present() -> Bool {
        true
    }

    private func accessibility(of item: DeviceItemTag) -> CFString {
        switch deviceItemClass(item: item) {
        case .keys:
            return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .anchor:
            return passcodeIsSet()
                ? kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
                : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }

    // Synchronizable is part of an item's identity, so a synced item of the same name is never read or replaced.
    private func query(_ item: DeviceItemTag) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account(item),
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    // Each part escaped, since an origin holds slashes.
    static func account(_ item: DeviceItemTag) -> String {
        let parts: [String]
        switch item {
        case let .deviceKeys(origin, account, deviceRow):
            parts = ["device-keys", origin, account, deviceRow]
        case let .accountKeys(origin, account, av):
            parts = ["account-keys", origin, account, String(av)]
        case let .resetKeys(origin, account, reset):
            parts = ["reset-keys", origin, account, reset]
        case let .stateMacKey(state):
            parts = ["state-mac-key", state]
        case let .anchorRoot(state):
            parts = ["anchor-root", state]
        case let .anchorCheckpoint(state, checkpoint, part):
            parts = ["anchor-checkpoint", state, checkpoint, String(part)]
        }
        return parts.map { $0.addingPercentEncoding(withAllowedCharacters: unescaped) ?? $0 }.joined(separator: "/")
    }

    private static let unescaped = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private static func error(_ status: OSStatus) -> HostSecretError {
        switch status {
        case errSecInteractionNotAllowed:
            return .Locked
        case errSecUserCanceled:
            return .Dismissed
        case errSecMissingEntitlement, errSecNotAvailable, errSecNoSuchKeychain:
            return .Unavailable(detail: "Keychain error \(status)")
        default:
            return .Failed(detail: "Keychain error \(status)")
        }
    }

    // Any answer but "no passcode" keeps the passcode's class: a failed write then reports, where a guess the other
    // way would put the anchor where a backup brings it back.
    static func devicePasscodeIsSet() -> Bool {
        var error: NSError?
        if LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            return true
        }
        return error?.code != LAError.Code.passcodeNotSet.rawValue
    }
}
