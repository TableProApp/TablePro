import Foundation
import Security
@testable import TableProMobile

// As Keychain Services documents: no synchronizable key or false finds device-only items, true synced ones, Any both.
final class InMemoryKeychainItems: KeychainItemStore, @unchecked Sendable {
    private struct Item {
        let service: String
        let account: String
        let synchronizable: Bool
        var data: Data
        var accessible: String
        var modified: Date
    }

    private enum Scope {
        case deviceOnly
        case synced
        case both
    }

    private static let deviceOnlyClasses: Set<String> = [
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
        kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String,
    ]

    private let lock = NSLock()
    private var items: [Item] = []
    private var refusedAdd: OSStatus?
    private var refusedUpdate: OSStatus?
    private var writes = 0
    private var callsOnMainThread = 0
    private var listingHook: (@Sendable () -> Void)?

    // Calls made on the main thread, where a real Keychain call blocks the UI.
    var mainThreadCalls: Int {
        lock.withLock { callsOnMainThread }
    }

    // Runs inside the next listing, before it reads the items, as a save landing mid-listing would.
    func duringNextListing(_ hook: @escaping @Sendable () -> Void) {
        lock.withLock { listingHook = hook }
    }

    private func countIfMainThread() {
        guard Thread.isMainThread else { return }
        lock.withLock { callsOnMainThread += 1 }
    }

    // Each write is one tick later than the one before, as a later save on any device would be.
    private func nextDate() -> Date {
        writes += 1
        return Date(timeIntervalSinceReferenceDate: TimeInterval(writes))
    }

    var failedAdd: OSStatus? {
        get { lock.withLock { refusedAdd } }
        set { lock.withLock { refusedAdd = newValue } }
    }

    var failedUpdate: OSStatus? {
        get { lock.withLock { refusedUpdate } }
        set { lock.withLock { refusedUpdate = newValue } }
    }

    func seed(_ value: String, service: String = "com.TablePro", account: String, synchronizable: Bool) {
        let accessible = synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock as String
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        lock.withLock {
            items.removeAll { $0.service == service && $0.account == account && $0.synchronizable == synchronizable }
            items.append(Item(
                service: service,
                account: account,
                synchronizable: synchronizable,
                data: Data(value.utf8),
                accessible: accessible,
                modified: nextDate()
            ))
        }
    }

    func value(service: String = "com.TablePro", account: String, synchronizable: Bool) -> String? {
        lock.withLock { () -> String? in
            guard let item = stored(service: service, account: account, synchronizable: synchronizable) else { return nil }
            return String(decoding: item.data, as: UTF8.self)
        }
    }

    func accessibility(service: String = "com.TablePro", account: String, synchronizable: Bool) -> String? {
        lock.withLock { () -> String? in
            stored(service: service, account: account, synchronizable: synchronizable)?.accessible
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock { () -> OSStatus in
            if let refusedAdd { return refusedAdd }
            guard let service = attributes[kSecAttrService as String] as? String,
                  let account = attributes[kSecAttrAccount as String] as? String,
                  let data = attributes[kSecValueData as String] as? Data,
                  let accessible = attributes[kSecAttrAccessible as String] as? String else { return errSecParam }
            let synchronizable: Bool
            switch Self.scope(of: attributes) {
            case .deviceOnly: synchronizable = false
            case .synced: synchronizable = true
            case .both: return errSecParam
            }
            if synchronizable, Self.deviceOnlyClasses.contains(accessible) { return errSecParam }
            guard stored(service: service, account: account, synchronizable: synchronizable) == nil else {
                return errSecDuplicateItem
            }
            items.append(Item(
                service: service,
                account: account,
                synchronizable: synchronizable,
                data: data,
                accessible: accessible,
                modified: nextDate()
            ))
            return errSecSuccess
        }
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.withLock { () -> OSStatus in
            if let refusedUpdate { return refusedUpdate }
            let matched = matches(query)
            guard !matched.isEmpty else { return errSecItemNotFound }
            let accessible = attributes[kSecAttrAccessible as String] as? String
            if let accessible, Self.deviceOnlyClasses.contains(accessible),
               matched.contains(where: { items[$0].synchronizable }) {
                return errSecParam
            }
            for index in matched {
                if let data = attributes[kSecValueData as String] as? Data { items[index].data = data }
                if let accessible { items[index].accessible = accessible }
                items[index].modified = nextDate()
            }
            return errSecSuccess
        }
    }

    func copyItem(_ query: [String: Any]) -> KeychainCopiedItem {
        lock.withLock { () -> KeychainCopiedItem in
            guard let index = matches(query).first else {
                return KeychainCopiedItem(status: errSecItemNotFound, data: nil, modified: nil)
            }
            return KeychainCopiedItem(status: errSecSuccess, data: items[index].data, modified: items[index].modified)
        }
    }

    func accounts(_ query: [String: Any]) -> [String] {
        countIfMainThread()
        let hook = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { listingHook = nil }
            return listingHook
        }
        hook?()
        return lock.withLock { matches(query).map { items[$0].account } }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        countIfMainThread()
        return lock.withLock { () -> OSStatus in
            let matched = Set(matches(query))
            guard !matched.isEmpty else { return errSecItemNotFound }
            items = items.enumerated().filter { !matched.contains($0.offset) }.map { $0.element }
            return errSecSuccess
        }
    }

    private func stored(service: String, account: String, synchronizable: Bool) -> Item? {
        items.first { $0.service == service && $0.account == account && $0.synchronizable == synchronizable }
    }

    private func matches(_ query: [String: Any]) -> [Int] {
        let service = query[kSecAttrService as String] as? String
        let account = query[kSecAttrAccount as String] as? String
        let scope = Self.scope(of: query)
        return items.indices.filter { index in
            let item = items[index]
            guard service == nil || item.service == service, account == nil || item.account == account else { return false }
            switch scope {
            case .deviceOnly: return !item.synchronizable
            case .synced: return item.synchronizable
            case .both: return true
            }
        }
    }

    private static func scope(of query: [String: Any]) -> Scope {
        guard let value = query[kSecAttrSynchronizable as String] else { return .deviceOnly }
        if let flag = value as? Bool { return flag ? .synced : .deviceOnly }
        if let text = value as? String, text == kSecAttrSynchronizableAny as String { return .both }
        return .deviceOnly
    }
}
