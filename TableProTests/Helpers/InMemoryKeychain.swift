//
//  InMemoryKeychain.swift
//  TableProTests
//

import Foundation
@testable import TablePro

final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: String] = [:]

    @discardableResult
    func writeString(_ value: String, forKey key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        store[key] = value
        return true
    }

    func readStringResult(forKey key: String) -> KeychainStringResult {
        lock.lock()
        defer { lock.unlock() }
        guard let value = store[key] else { return .notFound }
        return .found(value)
    }

    func delete(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        store[key] = nil
    }
}
