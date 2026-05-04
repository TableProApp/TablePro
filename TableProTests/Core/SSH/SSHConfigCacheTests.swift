//
//  SSHConfigCacheTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SSH config cache")
struct SSHConfigCacheTests {
    @Test("Returns cached document while file unchanged")
    func cachedReadIsStable() async throws {
        let url = try writeTempConfig("""
        Host alpha
            HostName 1.1.1.1
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = SSHConfigCache(configPath: url.path(percentEncoded: false))
        let first = await cache.current()
        let second = await cache.current()
        #expect(first.blocks.count == second.blocks.count)
        #expect(first == second)
    }

    @Test("Re-parses after file mtime changes")
    func mtimeInvalidates() async throws {
        let url = try writeTempConfig("""
        Host alpha
            HostName 1.1.1.1
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = SSHConfigCache(configPath: url.path(percentEncoded: false))
        let initial = await cache.current()
        #expect(extractHostName(initial, alias: "alpha") == "1.1.1.1")

        // Bump mtime two seconds forward to be safely outside hfs second-resolution
        try "Host alpha\n    HostName 9.9.9.9\n".write(to: url, atomically: true, encoding: .utf8)
        let attributes: [FileAttributeKey: Any] = [.modificationDate: Date(timeIntervalSinceNow: 2)]
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path(percentEncoded: false))

        let updated = await cache.current()
        #expect(extractHostName(updated, alias: "alpha") == "9.9.9.9")
    }

    @Test("Returns empty document when file missing")
    func missingFile() async {
        let path = NSTemporaryDirectory() + "tablepro-ssh-missing-\(UUID().uuidString)"
        let cache = SSHConfigCache(configPath: path)
        let document = await cache.current()
        #expect(document.blocks.isEmpty)
    }

    // MARK: - Helpers

    private func writeTempConfig(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-ssh-config-\(UUID().uuidString)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func extractHostName(_ document: SSHConfigDocument, alias: String) -> String? {
        for block in document.blocks {
            guard case .host(let patterns) = block.criteria else { continue }
            guard patterns.contains(where: { $0.glob == alias && !$0.negated }) else { continue }
            for directive in block.directives {
                if case .hostName(let value) = directive { return value }
            }
        }
        return nil
    }
}
