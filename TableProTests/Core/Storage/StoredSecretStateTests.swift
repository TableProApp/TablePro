//
//  StoredSecretStateTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

/// A keychain read that failed and a keychain read that found nothing both leave the connection
/// form's password field empty. Only one of them means the user cleared it.
private final class ScriptedKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var result: KeychainStringResult

    init(_ result: KeychainStringResult) {
        self.result = result
    }

    @discardableResult
    func writeString(_ value: String, forKey key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        result = .found(value)
        return true
    }

    func readStringResult(forKey key: String) -> KeychainStringResult {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    func delete(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        result = .notFound
    }
}

@MainActor
struct StoredSecretStateTests {
    private func makeStorage(_ result: KeychainStringResult) -> ConnectionStorage {
        let unique = UUID().uuidString
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent(unique)
            .appendingPathComponent("connections.json")
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return ConnectionStorage(
            fileURL: fileURL,
            userDefaults: UserDefaults(suiteName: "com.TablePro.tests.SecretState.\(unique)")!,
            keychain: ScriptedKeychain(result)
        )
    }

    @Test("A stored password reads as stored")
    func storedPassword() {
        #expect(makeStorage(.found("hunter2")).passwordState(for: UUID()) == .stored)
    }

    @Test("No keychain item reads as absent")
    func absentPassword() {
        #expect(makeStorage(.notFound).passwordState(for: UUID()) == .absent)
    }

    @Test("An empty stored value reads as absent rather than stored")
    func emptyStoredValueIsAbsent() {
        #expect(makeStorage(.found("")).passwordState(for: UUID()) == .absent)
    }

    @Test(
        "A keychain that could not be read reads as unreadable, never as absent",
        arguments: [
            KeychainStringResult.locked,
            .userCancelled,
            .authFailed,
            .error(-25_300),
        ]
    )
    func unreadableKeychain(_ result: KeychainStringResult) {
        #expect(makeStorage(result).passwordState(for: UUID()) == .unreadable)
    }

    @Test("The SSH namespaces answer the same way")
    func sshNamespaces() {
        let stored = makeStorage(.found("secret"))
        #expect(stored.sshPasswordState(for: UUID()) == .stored)
        #expect(stored.keyPassphraseState(for: UUID()) == .stored)

        let locked = makeStorage(.locked)
        #expect(locked.sshPasswordState(for: UUID()) == .unreadable)
        #expect(locked.keyPassphraseState(for: UUID()) == .unreadable)
    }
}
