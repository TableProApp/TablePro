//
//  StubKeychain.swift
//  TableProTests
//

import Foundation
@testable import TablePro

/// An in-memory `KeychainStoring`, so a test that stores a credential does not put one in the
/// Keychain of whoever is running the suite.
///
/// `@unchecked Sendable` with a lock rather than an actor or a `@MainActor` class: `KeychainStoring`
/// is a synchronous `Sendable` protocol, so a conformance isolated to an actor cannot satisfy it.
internal final class StubKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    internal init() {}

    @discardableResult
    internal func writeString(_ value: String, forKey key: String) -> Bool {
        lock.withLock { values[key] = value }
        return true
    }

    internal func readStringResult(forKey key: String) -> KeychainStringResult {
        guard let value = lock.withLock({ values[key] }) else { return .notFound }
        return .found(value)
    }

    internal func delete(forKey key: String) {
        lock.withLock { values.removeValue(forKey: key) }
    }
}
