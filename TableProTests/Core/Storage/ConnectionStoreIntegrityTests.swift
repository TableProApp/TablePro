//
//  ConnectionStoreIntegrityTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Connection store integrity")
struct ConnectionStoreIntegrityTests {
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

        #expect(ConnectionStoreIntegrity.verify(Data("[]".utf8), fileURL: fileURL) == .unstamped)
    }

    @Test("A stamped file verifies against its own bytes")
    func stampedFileIsTrusted() throws {
        let fileURL = makeTempFileURL()
        defer { cleanUp(fileURL) }

        let data = Data(#"[{"name":"Prod"}]"#.utf8)
        try #require(ConnectionStoreIntegrity.stamp(data, fileURL: fileURL))

        #expect(ConnectionStoreIntegrity.verify(data, fileURL: fileURL) == .trusted)
    }

    @Test("Changing a single byte is detected")
    func modifiedFileIsDetected() throws {
        let fileURL = makeTempFileURL()
        defer { cleanUp(fileURL) }

        let original = Data(#"[{"name":"Prod"}]"#.utf8)
        try #require(ConnectionStoreIntegrity.stamp(original, fileURL: fileURL))

        let tampered = Data(#"[{"name":"Prod!"}]"#.utf8)
        #expect(ConnectionStoreIntegrity.verify(tampered, fileURL: fileURL) == .modified)
    }

    @Test("A planted password source cannot be stamped without the key")
    func forgedTagIsRejected() throws {
        let fileURL = makeTempFileURL()
        defer { cleanUp(fileURL) }

        let original = Data(#"[{"name":"Prod"}]"#.utf8)
        try #require(ConnectionStoreIntegrity.stamp(original, fileURL: fileURL))

        let planted = Data(#"[{"name":"Prod","passwordSource":{"kind":"command","shell":"id"}}]"#.utf8)
        try Data(repeating: 0xAB, count: 32).write(to: ConnectionStoreIntegrity.tagURL(for: fileURL))

        #expect(ConnectionStoreIntegrity.verify(planted, fileURL: fileURL) == .modified)
    }

    @Test("An empty tag file is treated as no tag, not as a match")
    func emptyTagIsUnstamped() throws {
        let fileURL = makeTempFileURL()
        defer { cleanUp(fileURL) }

        try Data().write(to: ConnectionStoreIntegrity.tagURL(for: fileURL))

        #expect(ConnectionStoreIntegrity.verify(Data("[]".utf8), fileURL: fileURL) == .unstamped)
    }

    @Test("Constant-time comparison agrees with equality")
    func constantTimeComparison() {
        let a = Data([1, 2, 3, 4])
        #expect(ConnectionStoreIntegrity.constantTimeEquals(a, Data([1, 2, 3, 4])))
        #expect(!ConnectionStoreIntegrity.constantTimeEquals(a, Data([1, 2, 3, 5])))
        #expect(!ConnectionStoreIntegrity.constantTimeEquals(a, Data([1, 2, 3])))
    }
}
