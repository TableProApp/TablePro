//
//  SandboxKeychainStore.swift
//  TablePro
//

import Foundation

// A plain file in the sandbox, so a UI test's credentials never reach the login keychain, which a headless run cannot unlock.
internal final class SandboxKeychainStore: KeychainStoring {
    private let file: JSONFileStore<[String: String]>
    private let lock = NSLock()

    internal init(fileURL: URL) {
        file = JSONFileStore(url: fileURL)
    }

    @discardableResult
    internal func writeString(_ value: String, forKey key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var items = load()
        items[key] = value
        return persist(items)
    }

    internal func readStringResult(forKey key: String) -> KeychainStringResult {
        lock.lock()
        defer { lock.unlock() }
        guard let value = load()[key] else { return .notFound }
        return .found(value)
    }

    internal func delete(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        var items = load()
        guard items.removeValue(forKey: key) != nil else { return }
        _ = persist(items)
    }

    internal func deviceOnlyKeys(endingWith suffix: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return load().keys.filter { $0.hasSuffix(suffix) }
    }

    private func load() -> [String: String] {
        file.read().value ?? [:]
    }

    private func persist(_ items: [String: String]) -> Bool {
        (try? file.write(items)) != nil
    }
}
