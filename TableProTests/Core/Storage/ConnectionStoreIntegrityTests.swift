//
//  ConnectionStoreIntegrityTests.swift
//  TableProTests
//

import CryptoKit
import Foundation
import Testing

@testable import TablePro

/// The production source keeps its key in the keychain, which a headless CI runner has no
/// unlocked access to. The property under test is the HMAC, not where the key is stored.
private struct FixedIntegrityKeySource: IntegrityKeySource {
    let material: Data

    func key() -> SymmetricKey? { SymmetricKey(data: material) }
}

private struct MissingIntegrityKeySource: IntegrityKeySource {
    func key() -> SymmetricKey? { nil }
}

@Suite("Connection store integrity")
struct ConnectionStoreIntegrityTests {
    private let integrity = ConnectionStoreIntegrity(
        keySource: FixedIntegrityKeySource(material: Data(repeating: 0x5A, count: 32))
    )

    private func makeTempFileURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("connections_\(UUID().uuidString).json")
    }

    private func cleanUp(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: ConnectionStoreIntegrity.tagURL(for: fileURL))
    }

    @Test("A file with no tag reads as unstamped")
    func unstampedWithoutTag() {
        let fileURL = makeTempFileURL()
        defer { cleanUp(fileURL) }

        #expect(integrity.verify(Data("[]".utf8), fileURL: fileURL) == .unstamped)
    }

    @Test("A stamped file verifies against its own bytes")
    func stampedFileIsTrusted() throws {
        let fileURL = makeTempFileURL()
        defer { cleanUp(fileURL) }

        let data = Data(#"[{"name":"Prod"}]"#.utf8)
        try #require(integrity.stamp(data, fileURL: fileURL))

        #expect(integrity.verify(data, fileURL: fileURL) == .trusted)
    }

    @Test("Changing a single byte is detected")
    func modifiedFileIsDetected() throws {
        let fileURL = makeTempFileURL()
        defer { cleanUp(fileURL) }

        let original = Data(#"[{"name":"Prod"}]"#.utf8)
        try #require(integrity.stamp(original, fileURL: fileURL))

        let tampered = Data(#"[{"name":"Prod!"}]"#.utf8)
        #expect(integrity.verify(tampered, fileURL: fileURL) == .modified)
    }

    @Test("A planted password source cannot be stamped without the key")
    func forgedTagIsRejected() throws {
        let fileURL = makeTempFileURL()
        defer { cleanUp(fileURL) }

        let original = Data(#"[{"name":"Prod"}]"#.utf8)
        try #require(integrity.stamp(original, fileURL: fileURL))

        let planted = Data(#"[{"name":"Prod","passwordSource":{"kind":"command","shell":"id"}}]"#.utf8)
        try Data(repeating: 0xAB, count: 32).write(to: ConnectionStoreIntegrity.tagURL(for: fileURL))

        #expect(integrity.verify(planted, fileURL: fileURL) == .modified)
    }

    @Test("A tag written under a different key does not verify")
    func otherKeyDoesNotVerify() throws {
        let fileURL = makeTempFileURL()
        defer { cleanUp(fileURL) }

        let data = Data(#"[{"name":"Prod"}]"#.utf8)
        let other = ConnectionStoreIntegrity(
            keySource: FixedIntegrityKeySource(material: Data(repeating: 0x11, count: 32))
        )
        try #require(other.stamp(data, fileURL: fileURL))

        #expect(integrity.verify(data, fileURL: fileURL) == .modified)
    }

    @Test("An empty tag file is treated as no tag, not as a match")
    func emptyTagIsUnstamped() throws {
        let fileURL = makeTempFileURL()
        defer { cleanUp(fileURL) }

        try Data().write(to: ConnectionStoreIntegrity.tagURL(for: fileURL))

        #expect(integrity.verify(Data("[]".utf8), fileURL: fileURL) == .unstamped)
    }

    @Test("No key means unavailable, never a silent pass")
    func missingKeyIsUnavailable() {
        let fileURL = makeTempFileURL()
        defer { cleanUp(fileURL) }

        let withoutKey = ConnectionStoreIntegrity(keySource: MissingIntegrityKeySource())

        #expect(withoutKey.verify(Data("[]".utf8), fileURL: fileURL) == .unavailable)
        #expect(!withoutKey.stamp(Data("[]".utf8), fileURL: fileURL))
    }

    @Test("Constant-time comparison agrees with equality")
    func constantTimeComparison() {
        let a = Data([1, 2, 3, 4])
        #expect(ConnectionStoreIntegrity.constantTimeEquals(a, Data([1, 2, 3, 4])))
        #expect(!ConnectionStoreIntegrity.constantTimeEquals(a, Data([1, 2, 3, 5])))
        #expect(!ConnectionStoreIntegrity.constantTimeEquals(a, Data([1, 2, 3])))
    }
}
