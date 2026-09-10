//
//  SandboxKeychainStore.swift
//  TablePro
//

import Foundation
import os

/// The keychain a sandboxed run gets instead of the login keychain. Backed by a plain file inside
/// the sandbox, so a UI test's credentials never reach the real keychain and never survive the run.
///
/// A namespaced service string on the real keychain was the alternative and is worse: the items
/// would still be written to the user's login keychain, and reading them on a headless machine
/// needs the keychain unlocked, which is a documented CI failure mode. Nothing here is secret,
/// because nothing in a sandbox outlives the test that made it.
internal final class SandboxKeychainStore: KeychainStoring {
    private let fileURL: URL
    private let lock = NSLock()

    private static let logger = Logger(subsystem: "com.TablePro", category: "SandboxKeychainStore")

    internal init(fileURL: URL) {
        self.fileURL = fileURL
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

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return items
    }

    private func persist(_ items: [String: String]) -> Bool {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            Self.logger.error("Sandbox keychain write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
