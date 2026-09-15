//
//  UnreadableSecretKeychain.swift
//  TableProTests
//

import Foundation

@testable import TablePro

/// Every read reports a locked keychain, which is what a secret that exists but cannot be copied
/// looks like. Writes still succeed, so a test using it isolates the read half.
final class UnreadableSecretKeychain: KeychainStoring, @unchecked Sendable {
    @discardableResult
    func writeString(_ value: String, forKey key: String) -> Bool { true }

    func readStringResult(forKey key: String) -> KeychainStringResult { .locked }

    func delete(forKey key: String) {}
}
