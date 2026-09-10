//
//  RewindCipherTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

private final class FakeKeychain: KeychainStoring, @unchecked Sendable {
    private var values: [String: String] = [:]

    func writeString(_ value: String, forKey key: String) -> Bool {
        values[key] = value
        return true
    }

    func readStringResult(forKey key: String) -> KeychainStringResult {
        values[key].map { .found($0) } ?? .notFound
    }

    func delete(forKey key: String) {
        values.removeValue(forKey: key)
    }
}

private final class LockedKeychain: KeychainStoring, @unchecked Sendable {
    func writeString(_ value: String, forKey key: String) -> Bool { false }
    func readStringResult(forKey key: String) -> KeychainStringResult { .locked }
    func delete(forKey key: String) {}
}

@Suite("Rewind record protection")
struct RewindCipherTests {
    private func record() -> RewindRecord {
        RewindRecord(
            id: UUID(),
            historyId: nil,
            connectionId: UUID(),
            databaseType: .postgresql,
            target: DataWriteTarget(database: "shop", schema: "public", table: "users"),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            generatedColumns: ["search_vector"],
            operations: [
                RowWriteOperation(
                    kind: .update,
                    target: DataWriteTarget(database: "shop", schema: "public", table: "users"),
                    columns: ["id", "secret"],
                    primaryKeyColumns: ["id"],
                    preImage: ["7", .bytes(Data([0x01, 0x02, 0x03]))],
                    postImage: ["7", .bytes(Data([0x09]))],
                    writtenColumns: ["secret"],
                    refusal: nil
                ),
            ]
        )
    }

    @Test("A record survives a round trip through the cipher, binary values included")
    func roundTrip() throws {
        let cipher = RewindCipher(keychain: FakeKeychain())
        let original = record()

        let sealed = try cipher.seal(original)
        #expect(try cipher.open(sealed) == original)
    }

    @Test("The sealed bytes do not carry the row values in the clear")
    func sealedPayloadIsNotReadable() throws {
        let cipher = RewindCipher(keychain: FakeKeychain())
        let sealed = try cipher.seal(record())

        #expect(String(data: sealed, encoding: .utf8)?.contains("users") != true)
        #expect(sealed.range(of: Data("secret".utf8)) == nil)
    }

    @Test("Without the key nothing can be sealed or read")
    func lockedKeychainRefuses() throws {
        let cipher = RewindCipher(keychain: LockedKeychain())
        #expect(throws: RewindCipherError.self) { try cipher.seal(record()) }
    }

    @Test("A record sealed under one key cannot be read under another")
    func keyIsRequiredToRead() throws {
        let sealed = try RewindCipher(keychain: FakeKeychain()).seal(record())
        #expect(throws: (any Error).self) { try RewindCipher(keychain: FakeKeychain()).open(sealed) }
    }
}
