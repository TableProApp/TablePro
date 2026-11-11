import Foundation
@testable import TablePro

// One synced and one local value per key, as the keychain holds them. Only a delete that is not device-only removes
// a synced value.
final class ScopeRecordingKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var synced: [String: String] = [:]
    private var local: [String: String] = [:]
    private var unreadableKeys: Set<String> = []
    private var failingKeys: Set<String> = []

    func seedSynced(_ value: String, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        synced[key] = value
    }

    func seedLocal(_ value: String, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        local[key] = value
    }

    func makeUnreadable(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        unreadableKeys.insert(key)
    }

    func makeReadable(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        unreadableKeys.remove(key)
    }

    func failWrites(to key: String) {
        lock.lock()
        defer { lock.unlock() }
        failingKeys.insert(key)
    }

    func allowWrites(to key: String) {
        lock.lock()
        defer { lock.unlock() }
        failingKeys.remove(key)
    }

    func syncedValue(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return synced[key]
    }

    func localValue(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return local[key]
    }

    @discardableResult
    func writeString(_ value: String, forKey key: String) -> Bool {
        writeString(value, forKey: key, deviceOnly: false)
    }

    // Password sync is on in this model, so a write that is not device-only is a synced one.
    @discardableResult
    func writeString(_ value: String, forKey key: String, deviceOnly: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !failingKeys.contains(key) else { return false }
        if deviceOnly {
            local[key] = value
        } else {
            synced[key] = value
            local[key] = nil
        }
        return true
    }

    func readStringResult(forKey key: String) -> KeychainStringResult {
        readStringResult(forKey: key, deviceOnly: false)
    }

    func readStringResult(forKey key: String, deviceOnly: Bool) -> KeychainStringResult {
        lock.lock()
        defer { lock.unlock() }
        guard !unreadableKeys.contains(key) else { return .locked }
        let value = deviceOnly ? local[key] ?? synced[key] : synced[key] ?? local[key]
        return value.map { .found($0) } ?? .notFound
    }

    func delete(forKey key: String) {
        delete(forKey: key, deviceOnly: false)
    }

    func delete(forKey key: String, deviceOnly: Bool) {
        lock.lock()
        defer { lock.unlock() }
        local[key] = nil
        if !deviceOnly {
            synced[key] = nil
        }
    }
}
